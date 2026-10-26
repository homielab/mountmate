//  Created by homielab.com

import Foundation

/// Free and total space of a mounted file system, read without ever blocking
/// the caller on a hung volume.
enum FileSystemUsage {
  /// Mount points whose statfs has not returned yet. While one is still
  /// blocked (unresponsive disk), later refreshes skip it immediately
  /// instead of piling up more blocked threads.
  private static var statfsInFlight = Set<String>()
  private static let statfsLock = NSLock()
  private static let statfsQueue = DispatchQueue(
    label: "com.homielab.mountmate.statfs", qos: .utility, attributes: .concurrent)

  enum Outcome {
    case usage(total: Int64, free: Int64)
    /// No answer within the timeout (or still blocked from an earlier call).
    case timedOut
    case failed
  }

  /// Total and available bytes of the file system mounted at `path`. Never
  /// blocks the caller for longer than `timeout`.
  static func read(atPath path: String, timeout: TimeInterval = 2)
    -> Outcome
  {
    let started = statfsLock.withLock { statfsInFlight.insert(path).inserted }
    guard started else { return .timedOut }

    final class Box: @unchecked Sendable {
      var value: (total: Int64, free: Int64)?
    }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    statfsQueue.async {
      var stats = statfs()
      if statfs(path, &stats) == 0 {
        let blockSize = Int64(stats.f_bsize)
        // Same values FileManager reports as systemSize / systemFreeSize.
        box.value = (Int64(stats.f_blocks) * blockSize, Int64(stats.f_bavail) * blockSize)
      }
      Self.statfsLock.withLock { _ = Self.statfsInFlight.remove(path) }
      done.signal()
    }
    // The semaphore orders the write to `box` before this read.
    guard done.wait(timeout: .now() + timeout) == .success else { return .timedOut }
    guard let value = box.value else { return .failed }
    return .usage(total: value.total, free: value.free)
  }
}
