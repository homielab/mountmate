//  Created by homielab.com

import Foundation

/// Decides what "Unmount All Disks When the Screen Locks" does. Pure: the
/// app delegate observes the lock and unlock notifications and acts on the
/// answers.
enum ScreenLockRules {
  /// Settings → General → Behavior; off unless the user turned it on.
  static let enabledKey = "unmountOnScreenLockEnabled"

  /// Distributed notifications macOS posts when the screen locks and unlocks.
  static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
  static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

  enum Decision: Equatable {
    /// The setting is off.
    case off
    /// Nothing is mounted that the lock unmount may take away.
    case nothingToUnmount
    /// The unmount on sleep is running; it already unmounts the same disks.
    case sleepUnmountRunning
    /// Unmount the candidates.
    case unmount
  }

  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: enabledKey)
  }

  /// The volumes the lock unmount takes away: the "Unmount All" candidates
  /// (mounted, ordinary, not protected, not busy) without the volumes the
  /// user keeps mounted with Keep Alive.
  static func candidates(
    fromUnmountAll unmountAllCandidates: [Volume], isKeepAlive: (Volume) -> Bool
  ) -> [Volume] {
    unmountAllCandidates.filter { !isKeepAlive($0) }
  }

  static func decision(
    isEnabled: Bool, candidateCount: Int, isSleepUnmountRunning: Bool
  ) -> Decision {
    guard isEnabled else { return .off }
    guard !isSleepUnmountRunning else { return .sleepUnmountRunning }
    guard candidateCount > 0 else { return .nothingToUnmount }
    return .unmount
  }

  /// The screen is locked with the setting on: "Mount Again on Wake" waits
  /// for the unlock instead of mounting at wake, and a new plan (lock or
  /// sleep unmount) adds to the kept one instead of replacing it, so disks
  /// unmounted at lock come back at unlock even if the Mac slept in between.
  static func waitsForUnlock(isEnabled: Bool, isScreenLocked: Bool) -> Bool {
    isEnabled && isScreenLocked
  }
}
