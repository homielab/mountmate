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
    announced.formIntersection(mounted.map(\.id))
    if let threshold {
      for volume in mounted {
        if let used = volume.usagePercentage, used <= threshold - Self.rearmMargin {
          announced.remove(volume.id)
        }
      }
    }
    return LowSpaceRules.warnings(in: disks, threshold: threshold)
      .filter { announced.insert($0.volume.id).inserted }
  }

  typealias Warning = LowSpaceRules.Warning
}
