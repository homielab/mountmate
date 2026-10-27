//  Created by homielab.com

import Foundation

/// Runs `diskutil verifyVolume` off the main thread, at most once per volume
/// at a time. Verification only: the arguments come from
/// `VolumeVerificationRules.arguments(forDevice:)`, which never repairs.
final class VolumeVerifier: @unchecked Sendable {
  typealias Runner =
    @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval)
    -> ProcessResult

  static let diskutilPath = "/usr/sbin/diskutil"

  private let lock = NSLock()
  private var inFlight: Set<String> = []
  private let timeout: TimeInterval
  private let runner: Runner

  init(
    timeout: TimeInterval = VolumeVerificationRules.defaultTimeout,
    runner: @escaping Runner = { runProcess(executable: $0, arguments: $1, timeout: $2) }
  ) {
    self.timeout = timeout
    self.runner = runner
  }

  /// Starts verifying `deviceIdentifier` on a background queue and calls
  /// `completion` on the main queue with the result. Returns `false` (and
  /// runs nothing) when `volumeID` is already being verified.
  @discardableResult
  func verify(
    volumeID: String, deviceIdentifier: String,
    completion: @escaping @Sendable (ProcessResult) -> Void
  ) -> Bool {
    let started = lock.withLock { inFlight.insert(volumeID).inserted }
    guard started else { return false }

    let arguments = VolumeVerificationRules.arguments(forDevice: deviceIdentifier)
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let result = runner(Self.diskutilPath, arguments, timeout)
      lock.withLock { _ = inFlight.remove(volumeID) }
      DispatchQueue.main.async { completion(result) }
    }
    return true
  }

  func isVerifying(_ volumeID: String) -> Bool {
    lock.withLock { inFlight.contains(volumeID) }
  }
}
