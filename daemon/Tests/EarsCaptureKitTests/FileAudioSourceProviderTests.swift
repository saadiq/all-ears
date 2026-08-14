#if DEBUG

  import AVFoundation
  import EarsCore
  import Foundation
  import Testing

  @testable import EarsCaptureKit

  /// Tier-2 coverage for the file-backed capture source: a real `AVAudioEngine`
  /// driven from a WAV through the production tap/ring/generation pipeline. No
  /// TCC grant, no audio device, no live-mic audio — offline rendering
  /// throughout, so this half of the ground-truth corpus is hermetic and CI-able
  /// exactly as `test/ground-truth/README.md` claims.
  @Suite("FileAudioSourceProvider")
  struct FileAudioSourceProviderTests {
    private func testConfig() -> MicCaptureBackend.Config {
      MicCaptureBackend.Config(drainPollInterval: .milliseconds(1), enableStallWatchdog: false)
    }

    /// Write a mono 16-bit PCM WAV whose sample at index *i* is `value(i)`.
    private func writeWAV(
      frames: Int,
      sampleRate: Double = 48_000,
      channels: AVAudioChannelCount = 1,
      value: (Int, Int) -> Float
    ) throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-\(UUID().uuidString).wav")
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
      let file = try AVAudioFile(forWriting: url, settings: settings)
      let format = file.processingFormat
      let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
      buffer.frameLength = AVAudioFrameCount(frames)
      let data = try #require(buffer.floatChannelData)
      for channel in 0..<Int(format.channelCount) {
        for frame in 0..<frames { data[channel][frame] = value(channel, frame) }
      }
      try file.write(from: buffer)
      return url
    }

    private func drain(
      _ stream: AsyncStream<CapturedAudioBuffer>, until count: Int
    ) async -> [Float] {
      var collected: [Float] = []
      for await buffer in stream {
        collected.append(contentsOf: buffer.samples)
        if collected.count >= count { break }
      }
      return collected
    }

    @Test("the file's own samples flow through the production pipeline", .timeLimit(.minutes(1)))
    func fileSamplesReachTheStream() async throws {
      // A slow ramp: every sample is distinct, so a wrong offset, a repeat, or a
      // dropped block is visible rather than averaging out the way a tone would.
      let url = try writeWAV(frames: 24_000) { _, frame in Float(frame % 1000) / 1000.0 }
      defer { try? FileManager.default.removeItem(at: url) }

      let provider = try FileAudioSourceProvider(url: url, timing: .offlineManual)
      let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
      let stream = try await backend.start()
      for _ in 0..<24 { _ = try await backend.renderOfflineForTesting(frames: 512) }

      let collected = await drain(stream, until: 6 * 512)
      await backend.stop()

      #expect(collected.count >= 6 * 512)
      // The graph adds a latency tail, so match on content rather than on the
      // absolute index: find where the captured run starts in the file.
      let expected = (0..<24_000).map { Float($0 % 1000) / 1000.0 }
      let probe = Array(collected.prefix(64))
      let offset = (0..<(expected.count - 64)).first { start in
        zip(probe, expected[start..<(start + 64)]).allSatisfy { abs($0 - $1) < 1e-3 }
      }
      #expect(offset != nil, "the captured audio does not appear anywhere in the source file")
      if let offset {
        let window = min(collected.count, expected.count - offset)
        for i in 0..<window {
          #expect(abs(collected[i] - expected[offset + i]) < 1e-3)
        }
      }
      #expect(provider.framesRendered == 24 * 512)
    }

    @Test("past the end it emits silence and never loops", .timeLimit(.minutes(1)))
    func doesNotLoop() async throws {
      // Loud, short file: if the provider looped, the tail would be loud again,
      // and the whole slot schedule would slide out of alignment with the
      // recording — the failure `%noloop` was supposed to prevent in the browser.
      let url = try writeWAV(frames: 2_048) { _, _ in 0.5 }
      defer { try? FileManager.default.removeItem(at: url) }

      let provider = try FileAudioSourceProvider(url: url, timing: .offlineManual)
      let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
      let stream = try await backend.start()
      for _ in 0..<40 { _ = try await backend.renderOfflineForTesting(frames: 512) }

      let collected = await drain(stream, until: 16 * 512)
      await backend.stop()

      #expect(provider.reachedEnd)
      // Everything after the file's own length must be digital silence.
      let tail = collected.suffix(4 * 512)
      #expect(tail.allSatisfy { $0 == 0 }, "audio continued past the end of the file — it looped")
      #expect(collected.prefix(1_024).contains { $0 != 0 }, "the file's own audio never arrived")
    }

    @Test("a stereo file is downmixed to mono")
    func downmixesStereo() async throws {
      // Channels deliberately differ: a provider that took channel 0 (or 1)
      // rather than the mean would produce 1.0 or 0.0, not 0.5.
      let url = try writeWAV(frames: 4_096, channels: 2) { channel, _ in channel == 0 ? 1.0 : 0.0 }
      defer { try? FileManager.default.removeItem(at: url) }

      let provider = try FileAudioSourceProvider(url: url, timing: .offlineManual)
      let backend = MicCaptureBackend(source: "mic", provider: provider, config: testConfig())
      let stream = try await backend.start()
      for _ in 0..<16 { _ = try await backend.renderOfflineForTesting(frames: 512) }

      let collected = await drain(stream, until: 2_048)
      await backend.stop()

      let loud = collected.filter { $0 != 0 }
      #expect(!loud.isEmpty)
      #expect(loud.allSatisfy { abs($0 - 0.5) < 1e-3 }, "stereo was not downmixed to the mean")
    }

    @Test("duration is reported from the file, so a run can be checked against it")
    func reportsDuration() throws {
      let url = try writeWAV(frames: 96_000) { _, _ in 0.1 }
      defer { try? FileManager.default.removeItem(at: url) }
      let provider = try FileAudioSourceProvider(url: url, timing: .offlineManual)
      #expect(abs(provider.durationSeconds - 2.0) < 1e-6)
      #expect(!provider.reachedEnd)
      #expect(provider.framesRendered == 0)
    }

    @Test("a missing file fails at construction, not silently at capture time")
    func missingFileThrows() {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gt-does-not-exist-\(UUID().uuidString).wav")
      #expect(throws: (any Error).self) {
        _ = try FileAudioSourceProvider(url: url, timing: .offlineManual)
      }
    }

    @Test("the engine it hands back declares no bound input device")
    func doesNotClaimABoundDevice() throws {
      // `boundInputDevice` arms MicCaptureBackend's settle window that suppresses
      // configuration-change rebuilds. A file source induces no such change, so
      // claiming one would suppress a genuine route change for no reason.
      let url = try writeWAV(frames: 1_024) { _, _ in 0.2 }
      defer { try? FileManager.default.removeItem(at: url) }
      let provider = try FileAudioSourceProvider(url: url, timing: .offlineManual)
      let engine = try provider.makeCaptureEngine()
      #expect(!engine.boundInputDevice)
      #expect(engine.mode == .offlineManual)
      #expect(engine.tapFormat.channelCount == 1)
    }
  }

#endif
