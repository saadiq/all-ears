#if DEBUG

  import AVFoundation
  import Synchronization
  import os

  /// A ``CaptureEngineProvider`` that renders a WAV file through an injected
  /// `AVAudioSourceNode`, so a source's captured audio is a known recording
  /// instead of whatever the microphone hears.
  ///
  /// **Why this exists.** `earsd` captures the `mic` source through Core Audio,
  /// not through the browser. A ground-truth call drives the meeting's *outgoing*
  /// audio with Chrome's `--use-file-for-fake-audio-capture`, but that flag is
  /// invisible to this daemon — without this provider the `mic` source would go
  /// on recording the real room while Meet transmitted the corpus, and half the
  /// ground truth would be silently wrong. The browser flag and the daemon are
  /// separate consumers of the same file and each needs feeding. See
  /// `test/ground-truth/README.md`.
  ///
  /// They start on different clocks, deliberately: the two readers are
  /// independent and the scorer's zero-lag cross-correlation recovers the fixed
  /// offset by construction. Nothing here tries to synchronise them.
  ///
  /// **Compile-time gated, on purpose, and unlike the synthetic-backend switch
  /// next door.** `syntheticCaptureBackendEnvironmentKey` is gated on an
  /// environment variable and ships in the release binary, which is defensible
  /// because it emits a constant tone — nobody could mistake that for a
  /// recording. A file-backed microphone is different in kind: it can put
  /// arbitrary speech into a stored transcript that is indistinguishable from a
  /// real one. So this whole file is `#if DEBUG` and the release binary contains
  /// no code path that reads a file as a microphone. An environment variable
  /// still chooses the *path*, but only inside a build that already contains the
  /// capability.
  ///
  /// **The pipeline is the production one.** Like ``RealMicSourceProvider`` and
  /// the tests' `SyntheticSourceNodeProvider`, this only supplies the upstream
  /// node — the tap, ring, generation counter and frame-count handling in
  /// ``MicCaptureBackend`` are untouched and identical.
  public final class FileAudioSourceProvider: CaptureEngineProvider {
    /// How the engine is driven.
    public enum Timing: Sendable {
      /// Wall-clock. What the harness uses: the capture path's timing is being
      /// scored against a live call, so it has to run at the same rate as one.
      case realtime
      /// Manual offline rendering, pumped by the caller. What tests use — no
      /// audio device, no TCC, and deterministic.
      case offlineManual
    }

    /// The decoded file, held in memory and read from the render block.
    ///
    /// Preloaded rather than streamed because the render block runs on the
    /// realtime audio thread, where file I/O is forbidden. Stored as `Int16`
    /// (the WAVs are 16-bit PCM anyway), which halves the residency against
    /// `Float` and costs one multiply per sample in the render block.
    private final class Samples: Sendable {
      let frames: [Int16]
      let sampleRate: Double
      private let position = Atomic<Int>(0)

      init(frames: [Int16], sampleRate: Double) {
        self.frames = frames
        self.sampleRate = sampleRate
      }

      /// Frames rendered so far across every engine generation.
      var rendered: Int { position.load(ordering: .acquiring) }
      var reachedEnd: Bool { rendered >= frames.count }

      /// Fill `buffer` from the current position, padding with silence past the
      /// end. **Never loops** — a loop would slide the whole slot schedule out
      /// of alignment with the recording, and the run would score as drift.
      func render(into buffer: UnsafeMutablePointer<Float>, count: Int) {
        let start = position.wrappingAdd(count, ordering: .acquiringAndReleasing).oldValue
        for i in 0..<count {
          let index = start + i
          buffer[i] = index < frames.count ? Float(frames[index]) / 32768.0 : 0
        }
      }
    }

    private let samples: Samples
    private let timing: Timing
    private let url: URL
    private static let log = Logger(subsystem: "net.tomelliot.ears", category: "capture")

    /// - Parameters:
    ///   - url: A WAV (or anything `AVAudioFile` reads) to play as this source.
    ///   - timing: `.realtime` for a live harness run, `.offlineManual` for tests.
    public init(url: URL, timing: Timing = .realtime) throws {
      self.url = url
      self.timing = timing
      let file = try AVAudioFile(forReading: url)
      let format = file.processingFormat
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
      else {
        throw FileAudioSourceError.couldNotAllocateReadBuffer(url)
      }
      try file.read(into: buffer)

      guard let channels = buffer.floatChannelData else {
        throw FileAudioSourceError.unsupportedFormat(url, String(describing: format))
      }
      // Downmix to mono: the capture path is mono end to end, and a stereo file
      // whose channels differ would make "which channel did we capture" a
      // question the ground truth cannot answer.
      let count = Int(buffer.frameLength)
      let channelCount = Int(format.channelCount)
      var frames = [Int16](repeating: 0, count: count)
      for frame in 0..<count {
        var sum: Float = 0
        for channel in 0..<channelCount { sum += channels[channel][frame] }
        let value = max(-1.0, min(1.0, sum / Float(channelCount)))
        frames[frame] = Int16(value * 32767)
      }
      samples = Samples(frames: frames, sampleRate: format.sampleRate)
      Self.log.notice(
        """
        file-backed capture source loaded \(url.lastPathComponent, privacy: .public) \
        (\(count, privacy: .public) frames at \(format.sampleRate, privacy: .public) Hz) \
        — DEBUG build only
        """
      )
    }

    /// Frames the source node has rendered across every engine generation.
    public var framesRendered: Int { samples.rendered }
    /// Whether the file has been played to its end (after which it emits silence).
    public var reachedEnd: Bool { samples.reachedEnd }
    /// The file's own duration, for a caller asserting a run fits inside it.
    public var durationSeconds: Double { Double(samples.frames.count) / samples.sampleRate }

    public func makeCaptureEngine() throws -> CaptureEngine {
      let engine = AVAudioEngine()
      guard
        let format = AVAudioFormat(standardFormatWithSampleRate: samples.sampleRate, channels: 1)
      else {
        throw FileAudioSourceError.unsupportedFormat(url, "\(samples.sampleRate) Hz mono")
      }

      let samples = self.samples
      let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
          return noErr
        }
        samples.render(into: first, count: Int(frameCount))
        // Every extra buffer gets the same mono content, so a graph that hands
        // us a stereo layout does not capture one silent channel.
        for buffer in buffers.dropFirst() {
          guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
          data.update(from: first, count: Int(frameCount))
        }
        return noErr
      }

      engine.attach(source)
      engine.connect(source, to: engine.mainMixerNode, format: format)

      switch timing {
      case .offlineManual:
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
      case .realtime:
        // A realtime engine is pulled by the output device, which is what makes
        // it run at wall-clock speed — the whole point, since this source's
        // timing is scored against a live call. Silence the mixer so the
        // corpus is never played out of the machine's speakers: the tap sits on
        // the source node, upstream of this, so it is unaffected.
        engine.mainMixerNode.outputVolume = 0
      }

      return CaptureEngine(
        engine: engine,
        tapNode: source,
        tapBus: 0,
        tapFormat: format,
        mode: timing == .realtime ? .realtime : .offlineManual,
        boundInputDevice: false)
    }
  }

  public enum FileAudioSourceError: Error, CustomStringConvertible {
    case couldNotAllocateReadBuffer(URL)
    case unsupportedFormat(URL, String)

    public var description: String {
      switch self {
      case .couldNotAllocateReadBuffer(let url):
        return "could not allocate a read buffer for \(url.path)"
      case .unsupportedFormat(let url, let format):
        return "unsupported audio format for \(url.path): \(format)"
      }
    }
  }

#endif
