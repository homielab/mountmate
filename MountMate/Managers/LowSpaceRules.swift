//  Created by homielab.com

import Foundation

/// Decides which mounted volumes are "almost full". Pure: the row badge, the
/// notification and Copy Diagnostics all ask here.
enum LowSpaceRules {
  static let enabledKey = "lowSpaceWarningEnabled"
  static let thresholdKey = "lowSpaceWarningPercent"
  static let defaultPercent = 90
  static let percentChoices = [80, 90, 95]

  /// What the user sees for one volume.
  struct Warning: Equatable, Sendable {
    let percentUsed: Int
    /// Formatted free space (e.g. "12 GB"), when known.
    let free: String?
  }

  /// The configured threshold as a fraction, or nil when the warning is off.
  static func threshold(defaults: UserDefaults = .standard) -> Double? {
    if defaults.object(forKey: enabledKey) != nil, !defaults.bool(forKey: enabledKey) {
      return nil
    }
    let stored =
      defaults.object(forKey: thresholdKey) == nil
      ? defaultPercent : defaults.integer(forKey: thresholdKey)
    let percent = percentChoices.contains(stored) ? stored : defaultPercent
    return Double(percent) / 100
  }

  /// A warning when `volume` is mounted, writable, a user volume (not a
  /// system one) outside a disk image, and at least `threshold` full.
  static func warning(
    for volume: Volume, on diskType: PhysicalDiskType, threshold: Double?
  ) -> Warning? {
    guard let threshold, diskType != .diskImage, volume.isMounted, !volume.isReadOnly,
      volume.category == .user, volume.storageError == nil,
      let used = volume.usagePercentage
    else { return nil }
    // Half a percent of slack: 89.6% shows as "90%", so it must warn at 90.
    guard used >= threshold - 0.005 else { return nil }
    return Warning(percentUsed: Int((min(1, used) * 100).rounded()), free: volume.freeSpace)
  }

  /// A warning when a mounted network share is at least `threshold` full.
  /// A share that reports no size (`totalBytes` 0) gets none.
  static func warning(for usage: ShareUsage, threshold: Double?) -> Warning? {
    guard let threshold, usage.totalBytes > 0 else { return nil }
    let used = usage.percentage
    guard used >= threshold - 0.005 else { return nil }
    return Warning(
      percentUsed: Int((min(1, used) * 100).rounded()),
      free: ShareUsage.formatted(usage.freeBytes))
  }

  /// Volumes of `disks` that warrant a warning.
  static func warnings(
    in disks: [PhysicalDisk], threshold: Double?
  ) -> [(volume: Volume, warning: Warning)] {
    disks.flatMap { disk in
      disk.allVolumes.compactMap { volume in
        warning(for: volume, on: disk.type, threshold: threshold).map { (volume, $0) }
      }
    }
  }

  /// "Almost full: 94% used, 12 GB free" (tooltip and VoiceOver).
  static func message(for warning: Warning, bundle: Bundle = .main) -> String {
    if let free = warning.free {
      return String(
        format: NSLocalizedString(
          "Almost full: %1$d%% used, %2$@ free", bundle: bundle,
          comment: "Low space warning tooltip: percent used, free space"),
        warning.percentUsed, free)
    }
    return String(
      format: NSLocalizedString(
        "Almost full: %d%% used", bundle: bundle,
        comment: "Low space warning tooltip when the free space is unknown"),
      warning.percentUsed)
  }
}

/// Remembers which volumes were already announced, so a volume that stays full
/// is announced once. A volume is forgotten when it is unmounted or drops to
/// `rearmMargin` below the threshold, so it is announced again when it fills
/// up again; the margin keeps a volume hovering around the threshold from
/// being announced over and over. Not thread-safe: main queue only.
struct LowSpaceAlertTracker: Sendable {
  /// How far below the threshold (as a fraction) a volume must drop before it
  /// can be announced again.
  static let rearmMargin = 0.05

  private var announced: Set<String> = []

  /// The warnings of `disks` not announced yet; they count as announced
  /// afterwards. Volumes that are gone, unmounted or used at most
  /// `threshold - rearmMargin` are forgotten.
  mutating func newWarnings(
    in disks: [PhysicalDisk], threshold: Double?
  ) -> [(volume: Volume, warning: Warning)] {
    let mounted = disks.flatMap(\.allVolumes).filter(\.isMounted)
    forget(
      keeping: Set(mounted.map(\.id)),
      usage: mounted.compactMap { volume in volume.usagePercentage.map { (volume.id, $0) } },
      threshold: threshold)
    return LowSpaceRules.warnings(in: disks, threshold: threshold)
      .filter { announced.insert($0.volume.id).inserted }
  }

  /// The same for network shares: the warnings of `usage` (capacity by share
  /// ID) not announced yet. Shares no longer in `mountedShareIDs` or used at
  /// most `threshold - rearmMargin` are forgotten; a mounted share whose
  /// capacity could not be read keeps its state.
  mutating func newWarnings(
    shareUsage usage: [UUID: ShareUsage], mountedShareIDs: Set<UUID>, threshold: Double?
  ) -> [(shareID: UUID, warning: Warning)] {
    forget(
      keeping: Set(mountedShareIDs.map(\.uuidString)),
      usage: usage.filter { $0.value.totalBytes > 0 }.map {
        ($0.key.uuidString, $0.value.percentage)
      },
      threshold: threshold)
    return
      usage
      .filter { mountedShareIDs.contains($0.key) }
      .sorted { $0.key.uuidString < $1.key.uuidString }
      .compactMap { id, usage in
        LowSpaceRules.warning(for: usage, threshold: threshold).map { (id, $0) }
      }
      .filter { announced.insert($0.shareID.uuidString).inserted }
  }

  /// Drops what is not in `present`, and what is used (fraction) at most
  /// `threshold - rearmMargin`.
  private mutating func forget(
    keeping present: Set<String>, usage: [(key: String, used: Double)], threshold: Double?
  ) {
    announced.formIntersection(present)
    guard let threshold else { return }
    // A hair of tolerance: 0.95 - 0.05 is 0.8999…, so a volume or share at exactly 90%
    // would never count as dropped below the margin.
    let rearmBelow = threshold - Self.rearmMargin + 1e-9
    for (key, used) in usage where used <= rearmBelow {
      announced.remove(key)
    }
  }

  typealias Warning = LowSpaceRules.Warning
}
