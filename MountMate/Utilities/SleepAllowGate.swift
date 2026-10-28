//  Created by homielab.com

import Foundation

/// Answers one system sleep request (an IOKit kIOMessageSystemWillSleep)
/// exactly once while the sleep unmount runs, and caps how long a hung
/// unmount can keep the Mac awake.
///
/// - Feature off: `allow` runs at once and nothing is scheduled.
/// - Unmount finishes first (`complete()`): `allow` runs, the later timeout
///   does nothing.
/// - Timeout fires first: `onTimeout` runs, then `allow`; a later
///   `complete()` does nothing.
///
/// Not thread-safe: `complete()` and the scheduled timeout must run on the
/// same queue (the main queue in the app).
final class SleepAllowGate {
  /// Runs `work` after the given delay.
  typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

  static let mainQueueScheduler: Scheduler = { delay, work in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private let allowAction: () -> Void
  private let onTimeout: () -> Void
  private(set) var hasAllowed = false

  init(
    isEnabled: Bool,
    timeout: TimeInterval,
    schedule: Scheduler = SleepAllowGate.mainQueueScheduler,
    onTimeout: @escaping () -> Void,
    allow: @escaping () -> Void
  ) {
    allowAction = allow
    self.onTimeout = onTimeout
    guard isEnabled else {
      allowOnce()
      return
    }
    // The scheduled work keeps the gate alive until the timeout fires.
    schedule(timeout) { self.timeOut() }
  }

  /// The sleep unmount finished.
  func complete() {
    allowOnce()
  }

  private func timeOut() {
    if !hasAllowed { onTimeout() }
    allowOnce()
  }

  private func allowOnce() {
    guard !hasAllowed else { return }
    hasAllowed = true
    allowAction()
  }
}
