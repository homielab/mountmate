//  Created by homielab.com

import Foundation

enum PhysicalDiskType: Equatable, Sendable {
  case internalDisk
  case physical
  case diskImage
}

enum DriveCategory: Equatable, Sendable {
  case user
  case system
}

enum DiskTopology {
  static func isRAIDMaster(_ info: [String: Any]?) -> Bool {
    guard let info else { return false }
    if let value = info["RAIDMaster"] as? Bool { return value }
    if let value = info["RAIDMaster"] as? String {
      return ["yes", "true"].contains(value.lowercased())
    }
    return false
  }

  static func isRAIDMember(_ info: [String: Any]?, partitions: [[String: Any]]? = nil) -> Bool {
    if let partitions {
      for p in partitions {
        if let content = p["Content"] as? String,
          content == "Apple_RAID" || content == "Apple_RAID_Offline"
        {
          return true
        }
      }
    }
    guard let info, !isRAIDMaster(info) else { return false }
    if let value = info["RAIDMember"] as? Bool { return value }
    if let value = info["RAIDMember"] as? String {
      return ["yes", "true"].contains(value.lowercased())
    }
    // On some macOS releases a member identifies its master by BSD name.
    if let master = info["RAIDMaster"] as? String, master.hasPrefix("disk") { return true }
    return false
  }

  static func isTimeMachineVolume(_ volume: [String: Any]) -> Bool {
    if let role = volume["APFSVolumeRole"] as? String,
      role.localizedCaseInsensitiveContains("backup")
    {
      return true
    }
    if (volume["VolumeName"] as? String) == "Backups.backupdb" { return true }
    // Time Machine mounts its own backups and snapshots under a hidden
    // `.timemachine` folder.
    if let mountPoint = volume["MountPoint"] as? String {
      return mountPoint.split(separator: "/").contains(".timemachine")
    }
    return false
  }

  /// Sealed system snapshot volumes show up as a nested BSD slice of their
  /// origin volume (e.g. `disk5s1s1` for `disk5s1`) and mirror its name and
  /// usage, so listing them duplicates the row and skews disk statistics.
  static func isSealedSnapshotDevice(_ deviceIdentifier: String) -> Bool {
    deviceIdentifier.range(of: "^disk\\d+s\\d+s\\d+$", options: .regularExpression) != nil
  }

  /// Whole-disk entries without a mounted point or a volume name carry no
  /// mountable volume; they are bare OS-internal devices (e.g. cryptex RAM
  /// disks) rather than user-visible media.
  static func hasWholeDiskVolume(_ diskData: [String: Any]) -> Bool {
    let hasVolumeName = (diskData["VolumeName"] as? String)?.isEmpty == false
    let hasMountPoint = diskData["MountPoint"] != nil
    return hasVolumeName || hasMountPoint
  }
}

struct APFSSnapshot: Identifiable, Hashable, Sendable {
  let id: String  // UUID
  let name: String
}

struct Volume: Identifiable, Hashable, Sendable {
  /// The volume UUID, or the BSD identifier without one. Another volume in the
  /// same listing with the same UUID (cards flashed from one image, clones)
  /// makes it "<uuid>#<deviceIdentifier>"; see `isDuplicateUUID`.
  var id: String
  let deviceIdentifier: String
  let diskUUID: String?
  let name: String
  let isMounted: Bool
  let mountPoint: String?
  let freeSpace: String?
  let totalSize: String?
  let usedSpace: String?
  let usedBytes: Int64?
  let fileSystemType: String?
  let usagePercentage: Double?
  let category: DriveCategory
  var isProtected: Bool
  var snapshots: [APFSSnapshot]

  var storageError: String?

  /// Mounted read-only (see `DriveManager.mount(volume:readOnly:)`).
  var isReadOnly: Bool = false

  /// A Time Machine backup volume; see `DiskTopology.isTimeMachineVolume`.
  var isTimeMachine: Bool = false

  /// The volume's size in bytes, when diskutil reports one.
  var totalBytes: Int64?

  /// The user turned off the low-space warning for this volume.
  var isLowSpaceMuted: Bool = false

  /// Another listed volume has the same VolumeUUID. Such volumes have no
  /// `compositeId`, so no per-volume setting is saved or applied for them.
  var isDuplicateUUID: Bool = false

  /// The kernel's file system type of a mounted volume ("apfs", "ufsd_NTFS"…;
  /// `MountEntry.fileSystemType`), nil while unmounted. `fileSystemType` is
  /// the partition content instead, which can be vague ("Microsoft Basic Data").
  var mountedFileSystemType: String?

  /// The volume's UUID, or nil when the volume has none. DriveManager
  /// falls back to the BSD device identifier (e.g. "disk4s1") for `id`,
  /// which another volume can get later, so it must never be used to save
  /// per-volume settings.
  var stableVolumeUUID: String? {
    guard id != deviceIdentifier, UUID(uuidString: id) != nil else { return nil }
    return id
  }

  /// Key for per-volume settings (block, ignore, protect, pin, keep alive):
  /// "<disk UUID or NONE>-<volume UUID>". Nil when the volume has no UUID.
  /// DiskMounter builds the same key from Disk Arbitration descriptions.
  var compositeId: String? {
    guard let volumeUUID = stableVolumeUUID else { return nil }
    return "\(diskUUID ?? "NONE")-\(volumeUUID)"
  }

  var managedVolumeInfo: ManagedVolumeInfo? {
    guard let volumeUUID = stableVolumeUUID else { return nil }
    return ManagedVolumeInfo(
      volumeUUID: volumeUUID,
      diskUUID: diskUUID ?? "NONE",
      name: name
    )
  }

  /// Key for the ignore (hide) list only. Same as `compositeId`, except that
  /// a partition without a volume UUID (Microsoft Reserved, BitLocker,
  /// Linux, swap…) is identified by its partition DiskUUID, which is stable:
  /// "<DiskUUID>-<DiskUUID>". Hiding the wrong partition is harmless enough
  /// for this; settings that act on a volume (block, protect, pin, keep
  /// alive) stay volume-UUID-only.
  var ignoreIdentifier: String? {
    ignoreVolumeInfo?.id
  }

  /// The entry `PersistenceManager.ignore(volume:)` saves; see
  /// `ignoreIdentifier`.
  var ignoreVolumeInfo: ManagedVolumeInfo? {
    if let managedVolumeInfo { return managedVolumeInfo }
    guard let partitionUUID = Self.partitionIgnoreUUID(diskUUID) else { return nil }
    return ManagedVolumeInfo(volumeUUID: partitionUUID, diskUUID: partitionUUID, name: name)
  }

  /// `diskUUID` when it is a real UUID (kept as stored), else nil.
  static func partitionIgnoreUUID(_ diskUUID: String?) -> String? {
    guard let diskUUID, UUID(uuidString: diskUUID) != nil else { return nil }
    return diskUUID
  }
}

struct APFSContainer: Identifiable, Hashable, Sendable {
  let id: String  // deviceIdentifier
  var volumes: [Volume]
}

/// The drive's own health verdict, from `diskutil info`'s `SMARTStatus`.
enum SMARTStatus: String, Codable, Equatable, Sendable {
  case verified, failing, notSupported, unknown

  /// Maps diskutil's text ("Verified", "Failing", "Not Supported"); a missing
  /// or unrecognized value is `.unknown`.
  init(diskutilValue: String?) {
    switch diskutilValue?.trimmingCharacters(in: .whitespaces).lowercased() {
    case "verified": self = .verified
    case "failing": self = .failing
    case "not supported": self = .notSupported
    default: self = .unknown
    }
  }
}

struct PhysicalDisk: Identifiable, Equatable, Sendable {
  let id: String  // deviceIdentifier
  let diskUUID: String?
  let connectionType: String
  let name: String?
  let totalSize: String?
  let freeSpace: String?
  let usedSpace: String?
  let usagePercentage: Double?
  let type: PhysicalDiskType
  let isRAIDSet: Bool

  var partitions: [Volume]
  var containers: [APFSContainer]

  var storageError: String?
  var smartStatus: SMARTStatus = .unknown

  var hasVisibleContent: Bool {
    !partitions.isEmpty || containers.contains { !$0.volumes.isEmpty }
  }

  var allVolumes: [Volume] {
    partitions + containers.flatMap(\.volumes)
  }

  var isRemovable: Bool {
    type == .physical || type == .diskImage
  }
}
