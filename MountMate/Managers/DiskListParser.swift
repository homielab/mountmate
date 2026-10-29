//  Created by homielab.com

import DiskArbitration
import Foundation

/// Turns `diskutil list -plist` output, plus each whole disk's
/// `diskutil info -plist`, into the disks MountMate lists. It runs no process
/// itself: everything that touches the system (statfs, Disk Arbitration) is
/// injected, so it can be tested against recorded diskutil output.
struct DiskListParser {
  /// Composite IDs of ignored and protected volumes, copied on the main
  /// thread so background parsing never reads PersistenceManager's arrays
  /// while the UI mutates them.
  struct Filters: Sendable {
    var ignoredIDs: Set<String> = []
    var protectedIDs: Set<String> = []
  }

  struct Result {
    var disks: [PhysicalDisk]
    /// Disks listed without any classification (see
    /// `DriveManager.unverifiedDiskIDs`).
    var unverifiedDiskIDs: Set<String>
    /// A statfs timed out (or was still blocked from an earlier refresh).
    var usageTimedOut: Bool

    static let empty = Result(disks: [], unverifiedDiskIDs: [], usageTimedOut: false)
  }

  /// How a whole disk was classified when `diskutil info` was unavailable.
  enum FallbackDiskKind: CustomStringConvertible, Sendable {
    case internalDisk, external, diskImage, unknown
    var description: String {
      switch self {
      case .internalDisk: "internal"
      case .external: "external"
      case .diskImage: "disk image"
      case .unknown: "unknown"
      }
    }
  }

  var filters = Filters()
  var showInternalDisks = false
  /// Used and free space of a mounted volume whose list entry has no
  /// `CapacityInUse` (non-APFS volumes). Called concurrently, once per mount
  /// point, so one hung disk does not delay the others.
  var fileSystemUsage: @Sendable (String) -> FileSystemUsage.Outcome = { _ in .failed }
  /// Mount points of the file systems that are mounted read-only.
  var readOnlyMountPoints: Set<String> = []
  /// Second opinion for whole disks without `diskutil info`; disks missing
  /// from the result count as `.unknown`.
  var classifyDisksWithoutInfo: (Set<String>) -> [String: FallbackDiskKind] = { _ in [:] }

  // MARK: - Disk list

  static func allDisksAndPartitions(in plist: [String: Any]) -> [[String: Any]]? {
    plist["AllDisksAndPartitions"] as? [[String: Any]]
  }

  /// Whole physical disks: entries that are neither a partition of another
  /// entry nor a synthesized APFS container.
  static func rootDisks(in allDisksAndPartitions: [[String: Any]]) -> [[String: Any]] {
    var childDeviceIDs = Set<String>()
    for diskData in allDisksAndPartitions {
      if let partitions = diskData["Partitions"] as? [[String: Any]] {
        for partition in partitions {
          childDeviceIDs.insert(partition["DeviceIdentifier"] as? String ?? "")
        }
      }
    }

    return allDisksAndPartitions.filter { diskData in
      let deviceID = diskData["DeviceIdentifier"] as? String ?? ""
      let isSynthesizedAPFS = diskData["APFSPhysicalStores"] != nil
      return !childDeviceIDs.contains(deviceID) && !isSynthesizedAPFS
    }
  }

  /// - Parameters:
  ///   - rootInfo: `diskutil info -plist` per whole-disk identifier.
  ///   - unclassifiedDiskIDs: whole disks without any info; they are passed
  ///     to `classifyDisksWithoutInfo`.
  func parse(
    allDisksAndPartitions: [[String: Any]], rootInfo: [String: [String: Any]],
    unclassifiedDiskIDs: Set<String>
  ) -> Result {
    let fallbackKinds =
      unclassifiedDiskIDs.isEmpty ? [:] : classifyDisksWithoutInfo(unclassifiedDiskIDs)

    // A first pass only collects the mount points that need statfs; they are
    // then read in parallel, so several hung disks cost one timeout, not one
    // each.
    var usage = UsagePass()
    let firstPass = buildDisks(
      allDisksAndPartitions: allDisksAndPartitions, rootInfo: rootInfo,
      unclassifiedDiskIDs: unclassifiedDiskIDs, fallbackKinds: fallbackKinds, usage: &usage)
    guard !usage.requested.isEmpty else { return firstPass }

    usage.outcomes = Self.readUsageConcurrently(of: usage.requested, read: fileSystemUsage)
    return buildDisks(
      allDisksAndPartitions: allDisksAndPartitions, rootInfo: rootInfo,
      unclassifiedDiskIDs: unclassifiedDiskIDs, fallbackKinds: fallbackKinds, usage: &usage)
  }

  /// File system usage for one parse: collected first, then looked up.
  private struct UsagePass {
    /// nil while collecting the mount points to read.
    var outcomes: [String: FileSystemUsage.Outcome]?
    /// Mount points to read, in list order, without duplicates.
    var requested: [String] = []
    var timedOut = false

    /// The outcome for `mountPoint`, or nil while collecting.
    mutating func outcome(for mountPoint: String) -> FileSystemUsage.Outcome? {
      guard let outcomes else {
        if !requested.contains(mountPoint) { requested.append(mountPoint) }
        return nil
      }
      let outcome = outcomes[mountPoint] ?? .failed
      if case .timedOut = outcome { timedOut = true }
      return outcome
    }
  }

  /// Runs `read` for every mount point at once and waits for all of them.
  /// Each read gets its own pool thread (not `concurrentPerform`, whose width
  /// is the core count), so the wait is that of the slowest read.
  static func readUsageConcurrently(
    of mountPoints: [String], read: @escaping @Sendable (String) -> FileSystemUsage.Outcome
  ) -> [String: FileSystemUsage.Outcome] {
    final class Results: @unchecked Sendable {
      let lock = NSLock()
      var outcomes: [String: FileSystemUsage.Outcome] = [:]
    }
    let results = Results()
    let group = DispatchGroup()
    let queue = DispatchQueue.global(
      qos: DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .utility)
    for mountPoint in mountPoints {
      queue.async(group: group) {
        let outcome = read(mountPoint)
        results.lock.withLock { results.outcomes[mountPoint] = outcome }
      }
    }
    group.wait()
    return results.lock.withLock { results.outcomes }
  }

  private func buildDisks(
    allDisksAndPartitions: [[String: Any]], rootInfo: [String: [String: Any]],
    unclassifiedDiskIDs: Set<String>, fallbackKinds: [String: FallbackDiskKind],
    usage: inout UsagePass
  ) -> Result {
    var newDisks: [PhysicalDisk] = []
    var unverifiedDiskIDs = Set<String>()
    // A container spanning several physical stores (Fusion drive, or a
    // container across disks) is listed once, under the first store's disk.
    var listedContainerIDs = Set<String>()

    for diskData in Self.rootDisks(in: allDisksAndPartitions) {
      guard let physicalIdentifier = diskData["DeviceIdentifier"] as? String else { continue }
      let infoPlist = rootInfo[physicalIdentifier]
      let diskPartitions = diskData["Partitions"] as? [[String: Any]]
      if DiskTopology.isRAIDMember(infoPlist, partitions: diskPartitions) { continue }

      let isInternal: Bool
      let fallbackKind =
        unclassifiedDiskIDs.contains(physicalIdentifier)
        ? fallbackKinds[physicalIdentifier] ?? .unknown : nil
      if let infoPlist {
        isInternal = (infoPlist["Internal"] as? Bool) ?? false
      } else {
        // Only hide a disk positively known to be internal. A disk nothing
        // could classify is listed (as unverified, never removable) rather
        // than made to vanish.
        isInternal = fallbackKind == .internalDisk
      }
      if isInternal && !showInternalDisks { continue }

      var partitions: [Volume] = []
      var containers: [APFSContainer] = []

      if let diskPartitions {
        for partitionData in diskPartitions {
          if let contentType = partitionData["Content"] as? String,
            contentType == "Apple_APFS"
          {
            let storeID = partitionData["DeviceIdentifier"] as? String ?? ""
            if let containerData = Self.findAPFSContainer(
              forStore: storeID, in: allDisksAndPartitions),
              listedContainerIDs.insert(containerData["DeviceIdentifier"] as? String ?? storeID)
                .inserted,
              let container = createContainer(
                from: containerData, usage: &usage)
            {
              containers.append(container)
            }
          } else {
            if let volume = createVolume(
              from: partitionData, snapshotsData: nil, usage: &usage)
            {
              partitions.append(volume)
            }
          }
        }
      } else if diskData["APFSVolumes"] as? [[String: Any]] != nil {
        if let container = createContainer(from: diskData, usage: &usage) {
          containers.append(container)
        }
      }

      if partitions.isEmpty && containers.isEmpty, DiskTopology.hasWholeDiskVolume(diskData) {
        if let volume = createVolume(
          from: diskData, snapshotsData: nil, usage: &usage)
        {
          partitions.append(volume)
        }
      }

      if !partitions.isEmpty || !containers.isEmpty {
        let connectionInfo =
          infoPlist != nil
          ? Self.connectionInfo(from: infoPlist, isInternal: isInternal)
          : Self.fallbackConnectionInfo(for: fallbackKind ?? .unknown)
        let diskName =
          infoPlist?["IORegistryEntryName"] as? String ?? infoPlist?["MediaName"]
          as? String
          ?? (partitions.first ?? containers.first?.volumes.first)?.name
        let totalBytes = diskData["Size"] as? Int64 ?? 0

        let allVolumesForStats = partitions + containers.flatMap { $0.volumes }
        let stats = Self.parentDiskStats(totalBytes: totalBytes, volumes: allVolumesForStats)

        let physicalDisk = PhysicalDisk(
          id: physicalIdentifier, diskUUID: infoPlist?["DiskUUID"] as? String,
          connectionType: connectionInfo.type, name: diskName,
          totalSize: stats.total, freeSpace: stats.free, usedSpace: stats.used,
          usagePercentage: stats.percentage, type: connectionInfo.diskType,
          isRAIDSet: DiskTopology.isRAIDMaster(infoPlist),
          partitions: partitions, containers: containers, storageError: stats.error,
          smartStatus: SMARTStatus(diskutilValue: infoPlist?["SMARTStatus"] as? String))
        newDisks.append(physicalDisk)
        if infoPlist == nil, fallbackKind == nil || fallbackKind == .unknown {
          unverifiedDiskIDs.insert(physicalIdentifier)
        }
      }
    }

    let sortedDisks = newDisks.sorted {
      let order: (PhysicalDiskType) -> Int = { type in
        type == .internalDisk ? 0 : (type == .physical ? 1 : 2)
      }
      if order($0.type) != order($1.type) { return order($0.type) < order($1.type) }
      return ($0.name ?? "") < ($1.name ?? "")
    }
    return Result(
      disks: sortedDisks, unverifiedDiskIDs: unverifiedDiskIDs, usageTimedOut: usage.timedOut)
  }

  // MARK: - Disks

  /// The synthesized APFS container backed by `storeID`. A container can span
  /// several physical stores (e.g. a Fusion drive), so any of them matches.
  static func findAPFSContainer(forStore storeID: String, in allDisks: [[String: Any]])
    -> [String: Any]?
  {
    allDisks.first { disk in
      guard let physicalStores = disk["APFSPhysicalStores"] as? [[String: Any]] else {
        return false
      }
      return physicalStores.contains { ($0["DeviceIdentifier"] as? String) == storeID }
    }
  }

  /// Size, free and used space of a whole disk from the volumes listed on it.
  /// Any volume whose usage could not be read makes the whole disk show that
  /// error instead of numbers that leave it out.
  static func parentDiskStats(totalBytes: Int64, volumes: [Volume]) -> (
    total: String?, free: String?, used: String?, percentage: Double?, error: String?
  ) {
    if let errorMessage = volumes.compactMap(\.storageError).first {
      return (nil, nil, nil, nil, errorMessage)
    }
    guard totalBytes > 0 else { return (nil, nil, nil, nil, nil) }

    let usedBytes = volumes.reduce(0) { $0 + ($1.usedBytes ?? 0) }

    let formatter = byteCountFormatter()
    let totalSizeStr = formatter.string(fromByteCount: totalBytes)
    let freeBytes = totalBytes - usedBytes
    let freeSpaceStr = formatter.string(fromByteCount: freeBytes > 0 ? freeBytes : 0)
    let usedSpaceStr = formatter.string(fromByteCount: usedBytes)
    let usagePercentage = min(1.0, Double(usedBytes) / Double(totalBytes))

    return (totalSizeStr, freeSpaceStr, usedSpaceStr, usagePercentage, nil)
  }

  /// Connection label and disk type from a whole disk's `diskutil info`.
  static func connectionInfo(from infoPlist: [String: Any]?, isInternal: Bool) -> (
    type: String, diskType: PhysicalDiskType
  ) {
    let defaultType = NSLocalizedString("Unknown", comment: "Unknown connection type")
    guard let info = infoPlist else {
      return (defaultType, isInternal ? .internalDisk : .physical)
    }

    let isRAIDMaster = DiskTopology.isRAIDMaster(info)
    let isVirtual = info["VirtualOrPhysical"] as? String == "Virtual"

    let diskType: PhysicalDiskType
    if isInternal {
      diskType = .internalDisk
    } else if isVirtual && !isRAIDMaster {
      diskType = .diskImage
    } else {
      diskType = .physical
    }

    let connectionType: String
    if isRAIDMaster {
      connectionType = NSLocalizedString("Apple RAID", comment: "Apple RAID")
    } else if diskType == .diskImage {
      connectionType = NSLocalizedString("Disk Image", comment: "Disk Image")
    } else {
      connectionType = info["BusProtocol"] as? String ?? defaultType
    }

    return (connectionType, diskType)
  }

  /// Type for a disk without `diskutil info`. An unknown disk is typed as
  /// internal so nothing treats it as removable (`PhysicalDisk.isRemovable`);
  /// it is also in `unverifiedDiskIDs`.
  static func fallbackConnectionInfo(for kind: FallbackDiskKind) -> (
    type: String, diskType: PhysicalDiskType
  ) {
    let unknown = NSLocalizedString("Unknown", comment: "Unknown connection type")
    switch kind {
    case .external: return (unknown, .physical)
    case .diskImage: return (NSLocalizedString("Disk Image", comment: "Disk Image"), .diskImage)
    case .internalDisk, .unknown: return (unknown, .internalDisk)
    }
  }

  // MARK: - Containers and volumes

  private func createContainer(from containerData: [String: Any], usage: inout UsagePass)
    -> APFSContainer?
  {
    guard let containerID = containerData["DeviceIdentifier"] as? String,
      let apfsVolumesData = containerData["APFSVolumes"] as? [[String: Any]]
    else {
      return nil
    }

    var volumes: [Volume] = []
    for apfsVolumeData in apfsVolumesData {
      guard
        let deviceIdentifier = apfsVolumeData["DeviceIdentifier"] as? String,
        !DiskTopology.isSealedSnapshotDevice(deviceIdentifier)
      else { continue }
      if let volume = createVolume(
        from: apfsVolumeData,
        snapshotsData: apfsVolumeData["MountedSnapshots"] as? [[String: Any]],
        usage: &usage)
      {
        volumes.append(volume)
      }
    }
    let containerSize = apfsVolumesData.compactMap { $0["Size"] as? Int64 }.max() ?? 0
    return APFSContainer(
      id: containerID, volumes: Self.apfsContainerUsage(size: containerSize, volumes: volumes))
  }

  /// APFS volumes share their container's space: diskutil reports each
  /// volume's `Size` as the container size but `CapacityInUse` per volume.
  /// With several volumes, free space and usage are those of the whole
  /// container (as in Finder): free = size − the sum of every volume's use.
  /// `usedBytes` stays per volume so disk totals do not count it twice.
  static func apfsContainerUsage(size: Int64, volumes: [Volume]) -> [Volume] {
    guard size > 0, volumes.count > 1 else { return volumes }
    let used = volumes.reduce(Int64(0)) { $0 + ($1.usedBytes ?? 0) }
    let formatter = byteCountFormatter()
    let free = formatter.string(fromByteCount: max(0, size - used))
    let usedString = formatter.string(fromByteCount: used)
    let percentage = min(1, Double(used) / Double(size))
    return volumes.map { volume in
      guard volume.usedBytes != nil, volume.storageError == nil else { return volume }
      var updated = Volume(
        id: volume.id, deviceIdentifier: volume.deviceIdentifier, diskUUID: volume.diskUUID,
        name: volume.name, isMounted: volume.isMounted, mountPoint: volume.mountPoint,
        freeSpace: free, totalSize: volume.totalSize, usedSpace: usedString,
        usedBytes: volume.usedBytes, fileSystemType: volume.fileSystemType,
        usagePercentage: percentage, category: volume.category,
        isProtected: volume.isProtected, snapshots: volume.snapshots,
        storageError: volume.storageError)
      updated.isReadOnly = volume.isReadOnly
      updated.isTimeMachine = volume.isTimeMachine
      return updated
    }
  }

  private func createVolume(
    from volumeData: [String: Any], snapshotsData: [[String: Any]]?, usage: inout UsagePass
  ) -> Volume? {
    guard let deviceIdentifier = volumeData["DeviceIdentifier"] as? String else { return nil }

    let contentType = volumeData["Content"] as? String
    if contentType == "Apple_RAID" || contentType == "Apple_RAID_Offline" {
      return nil
    }

    let volumeUUID = volumeData["VolumeUUID"] as? String ?? deviceIdentifier
    let diskUUID = volumeData["DiskUUID"] as? String

    let volumeName =
      volumeData["VolumeName"] as? String ?? volumeData["Content"] as? String
      ?? deviceIdentifier

    let tempVolume = Volume(
      id: volumeUUID, deviceIdentifier: deviceIdentifier, diskUUID: diskUUID, name: volumeName,
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
    // Same matching as PersistenceManager.isVolumeIgnored/isVolumeProtected,
    // against the main-thread snapshot.
    let compositeId = tempVolume.compositeId
    // Volumes without a volume UUID (e.g. Microsoft Reserved) are ignored by
    // their partition UUID; see Volume.ignoreIdentifier.
    if let ignoreID = tempVolume.ignoreIdentifier, filters.ignoredIDs.contains(ignoreID) {
      return nil
    }

    let isProtected = compositeId.map { filters.protectedIDs.contains($0) } ?? false
    let snapshots = snapshotsData?.compactMap { Self.createSnapshot(from: $0) } ?? []

    let category: DriveCategory = contentType == "EFI" ? .system : .user

    let mountPoint: String?
    if let path = volumeData["MountPoint"] as? String {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && trimmed.caseInsensitiveCompare("Not Mounted") != .orderedSame {
        mountPoint = path
      } else {
        mountPoint = nil
      }
    } else {
      mountPoint = nil
    }
    let isMounted = mountPoint != nil
    let fileSystemType = contentType ?? (volumeData["FilesystemName"] as? String) ?? "Unknown"

    var freeSpaceStr: String?
    var totalSizeStr: String?
    var usedSpaceStr: String?
    var usagePercentage: Double?
    var usedBytes: Int64?
    var storageError: String?

    if let totalSize = volumeData["Size"] as? Int64, totalSize > 0 {
      let formatter = Self.byteCountFormatter()
      totalSizeStr = formatter.string(fromByteCount: totalSize)

      var calculatedUsedBytes: Int64?
      if let capacityInUse = volumeData["CapacityInUse"] as? Int64 {
        calculatedUsedBytes = capacityInUse
      } else if isMounted, let mountPoint = mountPoint,
        let outcome = usage.outcome(for: mountPoint)
      {
        // Non-APFS volumes: `diskutil list` has no usage, so ask the file
        // system. statfs needs no privacy permission, but it can block on an
        // unresponsive disk, so it is bounded by a timeout.
        switch outcome {
        case .usage(let total, let free):
          calculatedUsedBytes = total - free
        case .timedOut, .failed:
          Log.drive.error(
            "Could not read file system usage for \(volumeName, privacy: .private) (failed or timed out)."
          )
          storageError = NSLocalizedString(
            "Could not read storage details.",
            comment: "Shown when a volume's used/free space cannot be read")
        }
      }

      if let finalUsedBytes = calculatedUsedBytes {
        usedBytes = finalUsedBytes

        let freeBytes = totalSize - finalUsedBytes
        freeSpaceStr = formatter.string(fromByteCount: freeBytes > 0 ? freeBytes : 0)
        usedSpaceStr = formatter.string(fromByteCount: finalUsedBytes)
        usagePercentage = Double(finalUsedBytes) / Double(totalSize)
      }
    }

    return Volume(
      id: volumeUUID, deviceIdentifier: deviceIdentifier, diskUUID: diskUUID, name: volumeName,
      isMounted: isMounted, mountPoint: mountPoint, freeSpace: freeSpaceStr,
      totalSize: totalSizeStr, usedSpace: usedSpaceStr, usedBytes: usedBytes,
      fileSystemType: fileSystemType,
      usagePercentage: usagePercentage, category: category, isProtected: isProtected,
      snapshots: snapshots,
      storageError: storageError,
      isReadOnly: mountPoint.map { readOnlyMountPoints.contains($0) } ?? false,
      isTimeMachine: DiskTopology.isTimeMachineVolume(volumeData))
  }

  private static func createSnapshot(from snapshotData: [String: Any]) -> APFSSnapshot? {
    guard let name = snapshotData["SnapshotName"] as? String,
      let uuid = snapshotData["SnapshotUUID"] as? String
    else { return nil }
    return APFSSnapshot(id: uuid, name: name)
  }

  private static func byteCountFormatter() -> ByteCountFormatter {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB, .useKB, .useTB]
    formatter.countStyle = .file
    return formatter
  }
}

// MARK: - Disks without diskutil info

extension DiskListParser {
  /// Second opinions for disks without any info: Disk Arbitration first (no
  /// process), then `diskutil list external` once per refresh if needed.
  static func classifyWithSystem(_ identifiers: Set<String>)
    -> [String: FallbackDiskKind]
  {
    var kinds = [String: FallbackDiskKind]()
    let session = DASessionCreate(kCFAllocatorDefault)
    var externalWholeDiskIDs: Set<String>?
    var didListExternal = false
    for identifier in identifiers {
      var kind = session.map { diskArbitrationKind(of: identifier, session: $0) } ?? .unknown
      if kind == .unknown {
        if !didListExternal {
          didListExternal = true
          externalWholeDiskIDs = externalWholeDiskIdentifiers()
        }
        if externalWholeDiskIDs?.contains(identifier) == true { kind = .external }
      }
      kinds[identifier] = kind
      Log.drive.info(
        "Classified \(identifier, privacy: .public) without diskutil info as \(String(describing: kind), privacy: .public)."
      )
    }
    return kinds
  }

  /// Disk Arbitration's view of a whole disk: a fast, process-free second
  /// opinion when `diskutil info` failed.
  private static func diskArbitrationKind(of bsdName: String, session: DASession)
    -> FallbackDiskKind
  {
    guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
      let description = DADiskCopyDescription(disk) as? [String: Any]
    else { return .unknown }
    if (description[kDADiskDescriptionDeviceModelKey as String] as? String) == "Disk Image" {
      return .diskImage
    }
    guard let isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool
    else { return .unknown }
    return isInternal ? .internalDisk : .external
  }

  /// BSD names of the whole disks macOS reports as external
  /// (`diskutil list -plist external`). A cheap second source used only for
  /// disks whose `diskutil info` failed with nothing cached. Nil on failure.
  private static func externalWholeDiskIdentifiers() -> Set<String>? {
    let result = runProcess(
      executable: "/usr/sbin/diskutil", arguments: ["list", "-plist", "external"], timeout: 8)
    guard result.succeeded,
      let plist = PlistDecoding.decode(result.stdout, context: "diskutil list external"),
      let wholeDisks = plist["WholeDisks"] as? [String]
    else { return nil }
    return Set(wholeDisks)
  }
}
