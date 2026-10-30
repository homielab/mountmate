//  Created by homielab.com

import Foundation

/// Free and total space of a mounted file system, read without ever blocking
/// the caller on a hung volume.
enum FileSystemUsage {
  /// Paths whose `statfs` has not returned yet. While one is still blocked
  /// (unresponsive disk or server), later calls skip it immediately instead
  /// of piling up more blocked threads.
  private final class InFlightPaths: @unchecked Sendable {
    private var paths = Set<String>()
    private let lock = NSLock()

    func begin(_ path: String) -> Bool { lock.withLock { paths.insert(path).inserted } }
    func end(_ path: String) { lock.withLock { _ = paths.remove(path) } }
  }

  /// Carries the answer of the statfs queue back to the waiting caller.
  private final class Box<T>: @unchecked Sendable {
    var value: T?
  }

  /// Capacity reads (`read(atPath:timeout:)`).
  private static let reads = InFlightPaths()
  /// Keep Alive health checks (`probe(atPath:timeout:statfsCall:)`), kept
  /// apart so a capacity read running at the same moment is never mistaken
  /// for a blocked probe.
  private static let probes = InFlightPaths()
  private static let statfsQueue = DispatchQueue(
    label: "com.homielab.mountmate.statfs", qos: .utility, attributes: .concurrent)

  enum Outcome {
    case usage(total: Int64, free: Int64)
    /// No answer within the timeout (or still blocked from an earlier call).
    case timedOut
    case failed
  }

  /// Result of a health check of a mount point.
  enum ProbeOutcome: Equatable {
    case responding
    /// `statfs` returned this `errno`.
    case failed(errno: Int32)
    /// No answer within the timeout (or the previous probe is still blocked).
    case timedOut
  }

  /// Marks `path` as being read; false when a read of it is still running.
  static func beginRead(of path: String) -> Bool { reads.begin(path) }

  static func endRead(of path: String) { reads.end(path) }

  /// Runs `work` on the statfs queue and waits at most `timeout` for it.
  /// Nil on timeout, or at once when a call for `path` in `inFlight` is
  /// still running.
  private static func run<T>(
    path: String, inFlight: InFlightPaths, timeout: TimeInterval,
    _ work: @escaping @Sendable () -> T
  ) -> T? {
    guard inFlight.begin(path) else { return nil }

    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    statfsQueue.async {
      box.value = work()
      inFlight.end(path)
      done.signal()
    }
    // The semaphore orders the write to `box` before this read.
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return box.value
  }

  /// Total and available bytes of the file system mounted at `path`. Never
  /// blocks the caller for longer than `timeout`.
  static func read(atPath path: String, timeout: TimeInterval = 2)
    -> Outcome
  {
    let answer = run(path: path, inFlight: reads, timeout: timeout) {
      () -> (total: Int64, free: Int64)? in
      var stats = statfs()
      guard statfs(path, &stats) == 0 else { return nil }
      let blockSize = Int64(stats.f_bsize)
      // Same values FileManager reports as systemSize / systemFreeSize.
      return (Int64(stats.f_blocks) * blockSize, Int64(stats.f_bavail) * blockSize)
    }
    guard let answer else { return .timedOut }
    guard let value = answer else { return .failed }
    return .usage(total: value.total, free: value.free)
  }

  /// `statfs` of `path`: 0, or the `errno` it failed with.
  @Sendable static func statfsErrno(_ path: String) -> Int32 {
    var stats = statfs()
    return statfs(path, &stats) == 0 ? 0 : errno
  }

  /// Asks the file system mounted at `path` for its state (one `statfs`, a
  /// round trip to the server for a network share), at most one probe per
  /// path at a time. Never blocks the caller for longer than `timeout`.
  /// `statfsCall` returns 0 or an `errno` (tests pass a fake).
  static func probe(
    atPath path: String, timeout: TimeInterval,
    statfsCall: @escaping @Sendable (String) -> Int32 = statfsErrno
  ) -> ProbeOutcome {
    guard let code = run(path: path, inFlight: probes, timeout: timeout, { statfsCall(path) })
    else { return .timedOut }
    return code == 0 ? .responding : .failed(errno: code)
  }
}
