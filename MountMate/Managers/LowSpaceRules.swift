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
  /// A share that reports no size (`totalBytes` 0) or is read-only (set to
  /// mount read-only, or mounted so) gets none: nothing can be freed there.
  static func warning(
    for usage: ShareUsage, isReadOnly: Bool = false, threshold: Double?
  ) -> Warning? {
    guard let threshold, !isReadOnly, usage.totalBytes > 0 else { return nil }
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

  // MARK: - Background poll

  /// How often the free space of mounted external volumes is read again
  /// when nothing else refreshed the list (a drive plugged in for days fills
  /// up without any mount event).
  static let pollInterval: TimeInterval = 15 * 60

  /// What the poll timer should do.
  enum PollDecision: Equatable {
    /// No timer: notifications or the warning are off, or no external
    /// volume is mounted.
    case off
    /// Read the volumes again at this date.
    case wait(until: Date)
    case pollNow
  }

  /// Volumes the poll reads: mounted, writable user volumes of external
  /// disks. Internal disks and disk images are left out; network shares have
  /// their own throttled reads, so a NAS can sleep.
  static func pollCandidates(in disks: [PhysicalDisk]) -> [Volume] {
    disks.filter { $0.type == .physical }.flatMap(\.allVolumes).filter {
      $0.isMounted && $0.mountPoint != nil && !$0.isReadOnly && $0.category == .user
    }
  }

  /// Whether the poll is due: `pollInterval` after the last time volume
  /// usage was read (a list refresh or a poll).
  static func pollDecision(
    notificationsEnabled: Bool, threshold: Double?, disks: [PhysicalDisk], lastRead: Date,
    now: Date
  ) -> PollDecision {
    guard notificationsEnabled, threshold != nil, !pollCandidates(in: disks).isEmpty else {
      return .off
    }
    let due = lastRead.addingTimeInterval(pollInterval)
    return due > now ? .wait(until: due) : .pollNow
  }

  /// `disks` with the usage the poll read (by mount point) for its
  /// candidates. A volume whose read failed or timed out keeps its last
  /// values.
  static func applyingPolledUsage(
    _ outcomes: [String: FileSystemUsage.Outcome], to disks: [PhysicalDisk]
  ) -> [PhysicalDisk] {
    func update(_ volume: Volume) -> Volume {
      guard let mountPoint = volume.mountPoint,
        case .usage(let total, let free) = outcomes[mountPoint], total > 0
      else { return volume }
      let usage = ShareUsage(totalBytes: total, freeBytes: free)
      var updated = Volume(
        id: volume.id, deviceIdentifier: volume.deviceIdentifier, diskUUID: volume.diskUUID,
        name: volume.name, isMounted: volume.isMounted, mountPoint: volume.mountPoint,
        freeSpace: ShareUsage.formatted(max(0, free)), totalSize: volume.totalSize,
        usedSpace: ShareUsage.formatted(usage.usedBytes), usedBytes: volume.usedBytes,
        fileSystemType: volume.fileSystemType, usagePercentage: usage.percentage,
        category: volume.category, isProtected: volume.isProtected, snapshots: volume.snapshots,
        storageError: nil)
      updated.isReadOnly = volume.isReadOnly
      updated.isTimeMachine = volume.isTimeMachine
      return updated
    }
    return disks.map { disk in
      guard disk.type == .physical else { return disk }
      var disk = disk
      disk.partitions = disk.partitions.map(update)
      disk.containers = disk.containers.map { container in
        var container = container
        container.volumes = container.volumes.map(update)
        return container
      }
      return disk
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
