import Darwin
import EarsCore
import Foundation

/// A point-in-time reading of this process's own resource use.
///
/// Nothing in the daemon measured CPU or memory before. A capture path that
/// starts burning CPU, or an encoder that leaks, was previously invisible in
/// the logs — the only symptom would be a user noticing their machine had got
/// slow, with nothing in the record to confirm or refute it.
public struct ProcessResourceSample: Sendable, Equatable {
  /// User CPU time consumed since process start.
  public let userSeconds: Double
  /// System (kernel) CPU time consumed since process start.
  public let systemSeconds: Double
  /// Current resident set size in bytes, or nil where the kernel query failed.
  public let residentBytes: UInt64?
  /// High-water resident set size in bytes since process start.
  public let peakResidentBytes: UInt64
  /// Live thread count, or nil where the kernel query failed.
  public let threadCount: Int?

  public var cpuSeconds: Double { userSeconds + systemSeconds }

  public init(
    userSeconds: Double,
    systemSeconds: Double,
    residentBytes: UInt64?,
    peakResidentBytes: UInt64,
    threadCount: Int?
  ) {
    self.userSeconds = userSeconds
    self.systemSeconds = systemSeconds
    self.residentBytes = residentBytes
    self.peakResidentBytes = peakResidentBytes
    self.threadCount = threadCount
  }

  /// Log fields for a `proc.resource` record. `cpu_seconds` is cumulative;
  /// `cpu_percent` (added by the sampler when it has a previous sample) is the
  /// rate over the interval, which is the number worth alerting on.
  public var fields: [LogField] {
    var out: [LogField] = [
      LogField("cpu_seconds", .double((cpuSeconds * 1000).rounded() / 1000)),
      LogField("user_seconds", .double((userSeconds * 1000).rounded() / 1000)),
      LogField("system_seconds", .double((systemSeconds * 1000).rounded() / 1000)),
      LogField("peak_rss_bytes", .int(Int(peakResidentBytes))),
    ]
    if let residentBytes { out.append(LogField("rss_bytes", .int(Int(residentBytes)))) }
    if let threadCount { out.append(LogField("thread_count", .int(threadCount))) }
    return out
  }
}

public enum ProcessResources {
  /// Read this process's current resource use.
  ///
  /// CPU time and peak RSS come from `getrusage`; current RSS and thread count
  /// from the Mach task port. A failure in either Mach query degrades that one
  /// field to nil rather than failing the sample — resource telemetry must
  /// never be the thing that breaks a capture run.
  public static func sample() -> ProcessResourceSample {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    // On Darwin ru_maxrss is bytes (on Linux it would be kilobytes).
    let peak = UInt64(max(0, usage.ru_maxrss))

    return ProcessResourceSample(
      userSeconds: user,
      systemSeconds: system,
      residentBytes: residentSetSize(),
      peakResidentBytes: peak,
      threadCount: liveThreadCount())
  }

  private static func residentSetSize() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return info.resident_size
  }

  private static func liveThreadCount() -> Int? {
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else {
      return nil
    }
    // task_threads hands back a send right per thread plus the array's own
    // memory. Both must be released or this leaks a port right every sample —
    // and this runs on a timer for the life of the daemon.
    for index in 0..<Int(count) {
      mach_port_deallocate(mach_task_self_, threads[index])
    }
    vm_deallocate(
      mach_task_self_,
      vm_address_t(UInt(bitPattern: threads)),
      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    return Int(count)
  }
}

/// Periodically logs `proc.resource`, adding the interval CPU rate that a
/// cumulative counter alone can't give you.
public actor ProcessResourceLogger {
  private let sink: any LogRecordSink
  private let clock: any NowProviding
  private let tool: String
  private let subsystem: String
  private let category: String
  private let pid: Int32
  private let intervalSeconds: Double
  private var task: Task<Void, Never>?
  private var previous: (sample: ProcessResourceSample, at: Instant)?

  public init(
    sink: any LogRecordSink,
    clock: any NowProviding,
    tool: String,
    subsystem: String,
    category: String,
    pid: Int32,
    intervalSeconds: Double = 60
  ) {
    self.sink = sink
    self.clock = clock
    self.tool = tool
    self.subsystem = subsystem
    self.category = category
    self.pid = pid
    self.intervalSeconds = intervalSeconds
  }

  public func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(await self.intervalSeconds * 1_000_000_000))
        guard !Task.isCancelled else { return }
        await self.emit()
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  /// Sample and log once. Public so shutdown can take a final reading rather
  /// than losing the last interval.
  public func emit() async {
    let now = clock.now()
    let sample = ProcessResources.sample()
    var fields = sample.fields
    if let previous {
      let elapsed = now.interval(since: previous.at)
      if elapsed > 0 {
        let delta = sample.cpuSeconds - previous.sample.cpuSeconds
        fields.append(LogField("cpu_percent", .double((delta / elapsed * 1000).rounded() / 10)))
        fields.append(LogField("interval_seconds", .double((elapsed * 10).rounded() / 10)))
      }
    }
    previous = (sample, now)
    try? await sink.log(
      LogRecord(
        ts: now, level: .info, tool: tool, subsystem: subsystem, category: category, pid: pid,
        event: "proc.resource", fields: fields))
  }
}
