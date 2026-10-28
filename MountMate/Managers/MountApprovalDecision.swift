//  Created by homielab.com

import Foundation

/// Whether the Disk Arbitration mount approval callback lets a mount through.
/// Pure rules, no Disk Arbitration or UI work, so every branch is
/// unit-tested.
///
/// Facts that are costly or have side effects (consuming a single-use
/// approval, reading the bus protocol from the IORegistry, recording a disk
/// appearance) are closures, read lazily and in the same order as before so
/// a disk image never consumes an approval and the bus protocol is only read
/// when "Block USB Auto-Mount" is on.
enum MountApprovalDecision: Equatable {
  enum AllowReason: Equatable {
    /// Non-physical media (a disk image) is never blocked.
    case diskImage
    /// MountMate itself asked for this mount (single-use approval).
    case approvedByMountMate
    /// The volume is blocked, but "Allow Requested Mounts" is on and this is
    /// not the automatic mount right after the disk appeared.
    case requestedMount
    /// Nothing blocks the volume.
    case notBlocked
  }

  case allow(AllowReason)
  /// Refuse the mount. `blockedByList` is true when the per-volume blocked
  /// list (not only the global USB/SD block) matched, so a missing startup
  /// rule can be added for it.
  case dissent(blockedByList: Bool)

  struct Input {
    var isDiskImage: Bool
    /// Consumes MountMate's single-use approval for this disk, if any.
    var consumeApproval: () -> Bool
    var blockUSBAutoMount: Bool
    /// Bus protocol of the device ("USB", "SATA"…), nil when unknown.
    var busProtocol: () -> String?
    var volumeUUID: String?
    var diskUUID: String?
    /// True when the composite id (`MountApprovalDecision.blockedVolumeID`)
    /// is in the blocked volumes list.
    var isBlockedVolumeID: (String) -> Bool
    var allowRequestedMounts: Bool
    /// True while the mount is the automatic one right after the disk
    /// appeared (records the appearance when unknown).
    var isAutomaticMount: () -> Bool
  }

  static func decide(_ input: Input) -> MountApprovalDecision {
    if input.isDiskImage { return .allow(.diskImage) }

    // Only mount requests explicitly initiated by MountMate bypass the
    // runtime block. Disk Arbitration does not identify the source of a
    // request from Finder, Terminal, or the OS.
    if input.consumeApproval() { return .allow(.approvedByMountMate) }

    var shouldBlock = false
    var blockedByList = false

    // Global USB block. The feature is named "Block USB Auto-Mount", so it is
    // scoped to USB drives and SD cards.
    if input.blockUSBAutoMount, let proto = input.busProtocol(), isUSBOrSDProtocol(proto) {
      shouldBlock = true
    }

    if let id = blockedVolumeID(volumeUUID: input.volumeUUID, diskUUID: input.diskUUID),
      input.isBlockedVolumeID(id)
    {
      shouldBlock = true
      blockedByList = true
    }

    guard shouldBlock else { return .allow(.notBlocked) }
    if input.allowRequestedMounts && !input.isAutomaticMount() {
      return .allow(.requestedMount)
    }
    return .dissent(blockedByList: blockedByList)
  }

  /// Id of the volume in the blocked volumes list ("<disk UUID>-<volume
  /// UUID>", "NONE" for a missing disk UUID), or nil without a volume UUID.
  static func blockedVolumeID(volumeUUID: String?, diskUUID: String?) -> String? {
    guard let volumeUUID else { return nil }
    return "\(diskUUID ?? "NONE")-\(volumeUUID)"
  }

  /// "USB", "SD" or "Secure Digital", ignoring case and surrounding spaces.
  static func isUSBOrSDProtocol(_ proto: String) -> Bool {
    let value = proto.trimmingCharacters(in: .whitespaces)
    return ["USB", "SD", "Secure Digital"].contains {
      value.caseInsensitiveCompare($0) == .orderedSame
    }
  }
}
