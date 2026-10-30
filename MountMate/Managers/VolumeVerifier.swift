//  Created by homielab.com

import Foundation

/// Runs `diskutil verifyVolume` off the main thread, at most once per volume
/// at a time. Verification only: the arguments come from
/// `VolumeVerificationRules.arguments(forDevice:)`, which never repairs.
final class VolumeVerifier: @unchecked Sendable {
  /// Runs the command; calls `onLaunch` with the process once it started so
  /// it can be terminated early.
  typealias Runner =
    @Sendable (
      _ executable: String, _ arguments: [String], _ timeout: TimeInterval,
      _ onLaunch: @escaping @Sendable (Process) -> Void
    ) -> ProcessResult

  static let diskutilPath = "/usr/sbin/diskutil"

  private let lock = NSLock()
  private var inFlight: Set<String> = []
  private var cancelled: Set<String> = []
  private var processes: [String: Process] = [:]
  private let timeout: TimeInterval
  private let runner: Runner

  init(
    timeout: TimeInterval = VolumeVerificationRules.defaultTimeout,
    runner: @escaping Runner = { executable, arguments, timeout, onLaunch in
      runProcess(
        executable: executable, arguments: arguments, timeout: timeout, onLaunch: onLaunch)
    }
  ) {
    self.timeout = timeout
    self.runner = runner
  }

  /// Starts verifying `deviceIdentifier` on a background queue and calls
  /// `completion` on the main queue with the result, or nil when the run was
  /// cancelled. Returns `false` (and runs nothing) when `volumeID` is already
  /// being verified.
  @discardableResult
  func verify(
    volumeID: String, deviceIdentifier: String,
    completion: @escaping @Sendable (ProcessResult?) -> Void
  ) -> Bool {
    let started = lock.withLock { inFlight.insert(volumeID).inserted }
    guard started else { return false }

    let arguments = VolumeVerificationRules.arguments(forDevice: deviceIdentifier)
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let result = runner(Self.diskutilPath, arguments, timeout) { [self] process in
        let alreadyCancelled = lock.withLock {
          processes[volumeID] = process
          return cancelled.contains(volumeID)
        }
        if alreadyCancelled { process.terminate() }
      }
      let wasCancelled = lock.withLock {
        inFlight.remove(volumeID)
        processes[volumeID] = nil
        return cancelled.remove(volumeID) != nil
      }
      DispatchQueue.main.async { completion(wasCancelled ? nil : result) }
    }
    return true
  }

  func isVerifying(_ volumeID: String) -> Bool {
    lock.withLock { inFlight.contains(volumeID) }
  }

  /// Stops the verification of `volumeID`; its completion gets nil. Returns
  /// false when nothing was running.
  @discardableResult
  func cancel(_ volumeID: String) -> Bool {
    let process: Process?? = lock.withLock {
      guard inFlight.contains(volumeID) else { return nil }
      cancelled.insert(volumeID)
      return .some(processes[volumeID])
    }
    guard let process else { return false }
    process?.terminate()
    return true
  }

  /// Terminates every running verification (app quit), so no diskutil is
  /// left behind.
  func cancelAll() {
    let running = lock.withLock {
      cancelled.formUnion(inFlight)
      return Array(processes.values)
    }
    for process in running { process.terminate() }
  }
}
