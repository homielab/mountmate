//  Created by homielab.com

import Foundation

/// Keep Alive decisions about shares that are still in the mount table but
/// no longer answer (NAS restarted, Wi-Fi or VPN changed): such a mount
/// stays "mounted" and hangs Finder until macOS drops it.
enum StaleMountRules {
  /// How long a health check of a mounted share may take before the share
  /// counts as stale. A server that does not answer `statfs` in this time
  /// also leaves Finder waiting.
  static let probeTimeout: TimeInterval = 10

  /// `errno` values of a mount whose connection is gone.
  static let staleErrnos: Set<Int32> = [ESTALE, ENOTCONN, EIO]

  /// Whether the probe says the mount is stale: no answer in time, or a
  /// dead-connection error. Other errors (for example a permission error)
  /// mean the server answered.
  static func isStale(_ outcome: FileSystemUsage.ProbeOutcome) -> Bool {
    switch outcome {
    case .responding: return false
    case .timedOut: return true
    case .failed(let code): return staleErrnos.contains(code)
    }
  }

  /// The mount point to probe for a mounted share, or nil to leave it
  /// alone. Only mounts MountMate made (at the share's own folder) are
  /// checked: a mount elsewhere, such as the user's own Finder mount, is
  /// never force-unmounted. Suppressed shares (the user is unmounting
  /// them) and shares whose password was rejected (a remount could not
  /// sign in) are not checked either.
  static func probeTarget(
    mountPoint: String?, configuredMountPoint: String, isSuppressed: Bool,
    isCredentialRejected: Bool
  ) -> String? {
    guard let mountPoint, !isSuppressed, !isCredentialRejected,
      NetworkMountTable.samePath(mountPoint, configuredMountPoint)
    else { return nil }
    return mountPoint
  }

  /// Seconds between sweeps: the chosen interval, doubled in Low Power Mode
  /// to save battery.
  static func sweepInterval(retryInterval: TimeInterval, isLowPowerMode: Bool) -> TimeInterval {
    isLowPowerMode ? retryInterval * 2 : retryInterval
  }

  /// What `forceRemount` reports when the unmount failed and the share is
  /// still mounted (so no new mount is tried): a busy share is fine and
  /// counts as mounted, a stale one is still dead.
  static func remountResultWhenStillMounted(isStale: Bool) -> Bool {
    !isStale
  }
}
