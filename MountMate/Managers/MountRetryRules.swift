//  Created by homielab.com

import Foundation

/// When a failed `diskutil mount` is worth one more try. Pure decisions, no
/// process or UI work, so every branch is unit-tested.
struct MountRetryRules {
  /// Delay before retrying a mount that failed right after the disk appeared.
  static let retryDelay: TimeInterval = 5
  /// A volume listed for less than this long may still be settling (probing,
  /// MountMate's own auto-mount block), so a failed mount is retried once.
  static let recentAppearanceWindow: TimeInterval = 20

  /// A generic "failed to mount" is retried once only when it is plausibly
  /// transient: the volume appeared moments ago (`firstSeen` within `window`
  /// of `now`, or not listed yet) and diskutil did not say the file system is
  /// unsupported.
  static func shouldRetry(
    after result: ProcessResult, firstSeen: Date?, now: Date,
    window: TimeInterval = recentAppearanceWindow
  ) -> Bool {
    guard !result.succeeded, !result.timedOut else { return false }
    let error = result.stderr.lowercased()
    guard error.contains("failed to mount") else { return false }
    // diskutil's generic hint ("If the volume is damaged, try the readOnly
    // option") is printed for every failure, so "damaged" is no usable marker.
    let permanentMarkers = ["unrecognized", "not supported", "unsupported", "corrupt"]
    if permanentMarkers.contains(where: { error.contains($0) }) { return false }
    guard let firstSeen else { return true }
    return now.timeIntervalSince(firstSeen) < window
  }
}
