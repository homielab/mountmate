import DiskArbitration
import XCTest

@testable import MountMate

/// Runs `DiskListParser` against a recorded `diskutil list -plist` of a Mac
/// with an internal APFS disk (disk0, containers disk1–disk3) and two
/// external NTFS disks: disk6 "Samsung_T5" (mounted) and disk7 "One Touch"
/// (not mounted).
final class DiskListParserTests: XCTestCase {
  private static let samsungTotal: Int64 = 1_000_202_273_280
  private static let samsungFree: Int64 = 400_000_000_000

  private var allDisks: [[String: Any]] = []

  override func setUpWithError() throws {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "testDisks", withExtension: "plist"),
      "testDisks.plist fixture missing from the test bundle")
    let data = try Data(contentsOf: url)
    let plist = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any])
    allDisks = try XCTUnwrap(DiskListParser.allDisksAndPartitions(in: plist))
  }

  private let rootInfo: [String: [String: Any]] = [
    "disk0": ["Internal": true, "BusProtocol": "Apple Fabric", "MediaName": "APPLE SSD"],
    "disk6": [
      "Internal": false, "BusProtocol": "USB", "IORegistryEntryName": "Samsung PSSD T5 Media",
      "DiskUUID": "6A1B0C2D-0000-4000-8000-000000000006",
    ],
  ]

  private func parser(
    showInternalDisks: Bool = false, filters: DiskListParser.Filters = .init(),
    usage: FileSystemUsage.Outcome? = nil,
    fallback: [String: DiskListParser.FallbackDiskKind] = ["disk7": .external]
  ) -> DiskListParser {
    let usage = usage ?? .usage(total: Self.samsungTotal, free: Self.samsungFree)
    return DiskListParser(
      filters: filters, showInternalDisks: showInternalDisks,
      fileSystemUsage: { _ in usage },
      classifyDisksWithoutInfo: { ids in fallback.filter { ids.contains($0.key) } })
  }

  private func parse(_ parser: DiskListParser, unclassified: Set<String> = ["disk7"])
    -> DiskListParser.Result
  {
    parser.parse(
      allDisksAndPartitions: allDisks, rootInfo: rootInfo, unclassifiedDiskIDs: unclassified)
  }

  func testFixtureHasSixEntriesAndThreeWholeDisks() {
    XCTAssertEqual(allDisks.count, 6)
    let roots = DiskListParser.rootDisks(in: allDisks).compactMap {
      $0["DeviceIdentifier"] as? String
    }
    // disk1–disk3 are synthesized APFS containers, not physical disks.
    XCTAssertEqual(roots, ["disk0", "disk6", "disk7"])
  }

  func testSMARTStatusIsReadFromTheDiskInfo() throws {
    func status(_ value: Any?) -> SMARTStatus? {
      var info = rootInfo["disk6"] ?? [:]
      info["SMARTStatus"] = value
      var infos = rootInfo
      infos["disk6"] = info
      let result = parser().parse(
        allDisksAndPartitions: allDisks, rootInfo: infos, unclassifiedDiskIDs: ["disk7"])
      return result.disks.first { $0.id == "disk6" }?.smartStatus
    }
    XCTAssertEqual(status("Verified"), .verified)
    XCTAssertEqual(status("Failing"), .failing)
    XCTAssertEqual(status("Not Supported"), .notSupported)
    XCTAssertEqual(status(nil), .unknown)
    XCTAssertEqual(status("Something New"), .unknown)

    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "diskutilInfoSMARTFailing", withExtension: "plist"))
    let fixture = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])
    XCTAssertEqual(status(fixture["SMARTStatus"]), .failing)
  }

  func testMissingDiskListIsNil() {
    XCTAssertNil(DiskListParser.allDisksAndPartitions(in: ["WholeDisks": ["disk0"]]))
  }

  func testInternalDiskIsHiddenByDefault() {
    let result = parse(parser())

    XCTAssertEqual(result.disks.map(\.id), ["disk7", "disk6"])  // sorted by name
    XCTAssertEqual(result.disks.map(\.name), ["One Touch", "Samsung PSSD T5 Media"])
    XCTAssertTrue(result.disks.allSatisfy { $0.containers.isEmpty && $0.partitions.count == 1 })
    XCTAssertTrue(result.unverifiedDiskIDs.isEmpty)
    XCTAssertFalse(result.usageTimedOut)
  }

  func testInternalDiskIsListedFirstWhenShown() throws {
    let result = parse(parser(showInternalDisks: true))

    XCTAssertEqual(result.disks.map(\.id), ["disk0", "disk7", "disk6"])
    let internalDisk = result.disks[0]
    XCTAssertEqual(internalDisk.type, .internalDisk)
    XCTAssertEqual(internalDisk.name, "APPLE SSD")
    XCTAssertEqual(internalDisk.connectionType, "Apple Fabric")
    // disk0s2 is the store of container disk3; disk0s1 / disk0s3 are listed
    // as plain partitions.
    XCTAssertEqual(internalDisk.containers.map(\.id), ["disk3"])
    XCTAssertEqual(internalDisk.partitions.map(\.deviceIdentifier), ["disk0s1", "disk0s3"])
  }

  func testEjectAllSelectsTheTwoExternalDisksAndNotTheInternalOne() {
    let result = parse(parser(showInternalDisks: true))
    let candidates = BulkVolumeActions.ejectCandidates(
      in: result.disks, unverifiedDiskIDs: result.unverifiedDiskIDs)
    XCTAssertEqual(Set(candidates.map(\.id)), ["disk6", "disk7"])
  }

  func testAPFSContainerSkipsSealedSnapshotAndKeepsSnapshots() throws {
    let internalDisk = try XCTUnwrap(parse(parser(showInternalDisks: true)).disks.first)
    let container = try XCTUnwrap(internalDisk.containers.first)

    XCTAssertEqual(
      container.volumes.map(\.name),
      ["Macintosh HD", "Preboot", "Recovery", "Update", "Data", "VM"])
    XCTAssertFalse(container.volumes.contains { $0.deviceIdentifier == "disk3s1s1" })
    let system = container.volumes[0]
    XCTAssertEqual(system.snapshots.count, 1)
    XCTAssertFalse(system.isMounted)
    XCTAssertEqual(
      container.volumes.map(\.category), [.user, .system, .system, .system, .user, .system])
    XCTAssertEqual(container.volumes[4].mountPoint, "/System/Volumes/Data")
    XCTAssertEqual(container.volumes[4].usedBytes, 413_704_962_048)
  }

  func testHelperPartitionsAreSystemAndUserVolumesStayUser() {
    for content in [
      "EFI", "Apple_Boot", "Apple_APFS_Recovery", "Apple_APFS_ISC",
      "Microsoft Reserved", "Linux Swap", "Windows Recovery", "BIOS Boot",
    ] {
      XCTAssertEqual(
        DiskListParser.category(
          contentType: content, volumeName: nil, isAPFSVolume: false, isOSInternal: false),
        .system, content)
    }
    for content in ["Windows_NTFS", "Microsoft Basic Data", "Apple_HFS", "Linux Filesystem"] {
      XCTAssertEqual(
        DiskListParser.category(
          contentType: content, volumeName: "Recovery", isAPFSVolume: false, isOSInternal: false),
        .user, content)
    }
    for name in ["Preboot", "Recovery", "VM", "Update", "xART", "Hardware"] {
      XCTAssertEqual(
        DiskListParser.category(
          contentType: nil, volumeName: name, isAPFSVolume: true, isOSInternal: false),
        .system, name)
    }
    XCTAssertEqual(
      DiskListParser.category(
        contentType: nil, volumeName: "Photos", isAPFSVolume: true, isOSInternal: true), .system)
    XCTAssertEqual(
      DiskListParser.category(
        contentType: nil, volumeName: "Data", isAPFSVolume: true, isOSInternal: false), .user)
  }

  func testMountAllSkipsDiskWithOnlyHelperVolumes() throws {
    let internalDisk = try XCTUnwrap(parse(parser(showInternalDisks: true)).disks.first)
    let candidates = BulkVolumeActions.mountCandidates(in: [internalDisk]) { _ in false }
    let names = Set(candidates.map(\.name))
    XCTAssertTrue(names.isDisjoint(with: ["Preboot", "Recovery", "Update", "VM"]), "\(names)")
  }

  func testMountedNTFSVolumeUsesFileSystemUsage() throws {
    let samsung = try XCTUnwrap(parse(parser()).disks.first { $0.id == "disk6" })
    let volume = try XCTUnwrap(samsung.partitions.first)

    XCTAssertEqual(volume.name, "Samsung_T5")
    XCTAssertEqual(volume.mountPoint, "/Volumes/Samsung_T5")
    XCTAssertEqual(volume.fileSystemType, "Windows_NTFS")
    XCTAssertEqual(volume.category, .user)
    XCTAssertEqual(volume.usedBytes, Self.samsungTotal - Self.samsungFree)
    XCTAssertEqual(
      try XCTUnwrap(volume.usagePercentage),
      Double(Self.samsungTotal - Self.samsungFree) / Double(Self.samsungTotal), accuracy: 1e-9)
    XCTAssertNotNil(volume.freeSpace)
    XCTAssertNil(volume.storageError)
  }

  func testVolumeMountedReadOnlyIsMarked() throws {
    var readOnlyParser = parser()
    readOnlyParser.readOnlyMountPoints = ["/Volumes/Samsung_T5"]
    let marked = try XCTUnwrap(
      parse(readOnlyParser).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertTrue(marked.isReadOnly)

    let normal = try XCTUnwrap(parse(parser()).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertFalse(normal.isReadOnly)
  }

  func testVolumeFoundByTimeMachineDetectorIsMarked() throws {
    var detected = parser()
    detected.timeMachineMountPoints = ["/Volumes/Samsung_T5"]
    let marked = try XCTUnwrap(
      parse(detected).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertTrue(marked.isTimeMachine)

    let normal = try XCTUnwrap(parse(parser()).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertFalse(normal.isTimeMachine)
  }

  func testMountedVolumeGetsTheMountTableFileSystemType() throws {
    var withTypes = parser()
    withTypes.mountedFileSystemTypes = ["/Volumes/Samsung_T5": "ufsd_NTFS"]
    let marked = try XCTUnwrap(
      parse(withTypes).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertEqual(marked.mountedFileSystemType, "ufsd_NTFS")

    let normal = try XCTUnwrap(parse(parser()).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertNil(normal.mountedFileSystemType)
  }

  func testMountCommandMatchesDiskutilSyntax() throws {
    let volume = try XCTUnwrap(
      parse(parser()).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertEqual(
      DriveManager.mountArguments(for: volume, readOnly: false), ["mount", volume.deviceIdentifier])
    XCTAssertEqual(
      DriveManager.mountArguments(for: volume, readOnly: true),
      ["mount", "readOnly", volume.deviceIdentifier])
  }

  func testRemountKeepsReadOnlyMount() throws {
    var readOnlyParser = parser()
    readOnlyParser.readOnlyMountPoints = ["/Volumes/Samsung_T5"]
    let readOnly = try XCTUnwrap(
      parse(readOnlyParser).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertTrue(DriveManager.remountReadOnly(for: readOnly))
    XCTAssertEqual(
      DriveManager.mountArguments(
        for: readOnly, readOnly: DriveManager.remountReadOnly(for: readOnly)),
      ["mount", "readOnly", readOnly.deviceIdentifier])

    let writable = try XCTUnwrap(
      parse(parser()).disks.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertFalse(DriveManager.remountReadOnly(for: writable))
    XCTAssertEqual(
      DriveManager.mountArguments(
        for: writable, readOnly: DriveManager.remountReadOnly(for: writable)),
      ["mount", writable.deviceIdentifier])
  }

  func testParentDiskStatsComeFromItsVolumes() throws {
    let samsung = try XCTUnwrap(parse(parser()).disks.first { $0.id == "disk6" })

    XCTAssertEqual(samsung.connectionType, "USB")
    XCTAssertEqual(samsung.type, .physical)
    XCTAssertTrue(samsung.isRemovable)
    XCTAssertEqual(samsung.diskUUID, "6A1B0C2D-0000-4000-8000-000000000006")
    XCTAssertEqual(
      try XCTUnwrap(samsung.usagePercentage),
      Double(Self.samsungTotal - Self.samsungFree) / 1_000_204_886_016, accuracy: 1e-9)
    XCTAssertNotNil(samsung.totalSize)
    XCTAssertNil(samsung.storageError)
  }

  func testUsageTimeoutIsReportedAsStorageError() throws {
    let result = parse(parser(usage: .timedOut))
    let samsung = try XCTUnwrap(result.disks.first { $0.id == "disk6" })

    XCTAssertTrue(result.usageTimedOut)
    XCTAssertNotNil(samsung.partitions.first?.storageError)
    XCTAssertEqual(samsung.storageError, samsung.partitions.first?.storageError)
    XCTAssertNil(samsung.usagePercentage)
  }

  /// A USB hub with four mounted exFAT/NTFS volumes, one per disk.
  private static func fourUsageDisks() -> (disks: [[String: Any]], info: [String: [String: Any]]) {
    var disks: [[String: Any]] = []
    var info: [String: [String: Any]] = [:]
    for index in 0..<4 {
      let disk = "disk\(10 + index)"
      disks.append([
        "DeviceIdentifier": disk, "Size": Int64(1_000), "Content": "FDisk_partition_scheme",
        "Partitions": [
          [
            "DeviceIdentifier": "\(disk)s1",
            "Content": index.isMultiple(of: 2) ? "Windows_NTFS" : "ExFAT",
            "VolumeName": "Drive\(index)", "VolumeUUID": "UUID-\(index)", "Size": Int64(1_000),
            "MountPoint": "/Volumes/Drive\(index)",
          ]
        ],
      ])
      info[disk] = ["Internal": false, "BusProtocol": "USB", "MediaName": "Drive \(index)"]
    }
    return (disks, info)
  }

  func testUsageOfSeveralVolumesIsReadInParallel() throws {
    let (disks, info) = Self.fourUsageDisks()
    final class Reads: @unchecked Sendable {
      let lock = NSLock()
      var paths: [String] = []
    }
    let reads = Reads()
    let outcome: @Sendable (String) -> FileSystemUsage.Outcome = { path in
      if path == "/Volumes/Drive2" { return .timedOut }
      let index = Int64(path.last?.wholeNumberValue ?? 0)
      return .usage(total: 1_000, free: 100 * (index + 1))
    }
    func parse(sleep: TimeInterval) -> DiskListParser.Result {
      DiskListParser(
        fileSystemUsage: { path in
          reads.lock.withLock { reads.paths.append(path) }
          Thread.sleep(forTimeInterval: sleep)
          return outcome(path)
        }
      ).parse(allDisksAndPartitions: disks, rootInfo: info, unclassifiedDiskIDs: [])
    }

    let start = Date()
    let result = parse(sleep: 0.3)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 0.6, "4 reads of 0.3 s each must overlap")
    XCTAssertEqual(reads.paths.sorted(), (0..<4).map { "/Volumes/Drive\($0)" })

    // Same disks, in the same order, as when every read answers at once.
    let expected = DiskListParser(fileSystemUsage: outcome)
      .parse(allDisksAndPartitions: disks, rootInfo: info, unclassifiedDiskIDs: [])
    XCTAssertEqual(result.disks.map(\.id), ["disk10", "disk11", "disk12", "disk13"])
    XCTAssertEqual(result.disks, expected.disks)
    let volumes = result.disks.flatMap(\.partitions)
    XCTAssertEqual(volumes.map(\.usedBytes), [900, 800, nil, 600])
    XCTAssertNotNil(volumes[2].storageError)
    XCTAssertTrue(result.usageTimedOut)
    XCTAssertTrue(expected.usageTimedOut)
  }

  func testUsageIsReadOnceAndOnlyForMountedVolumesWithoutCapacity() {
    final class Reads: @unchecked Sendable {
      let lock = NSLock()
      var paths: [String] = []
    }
    let reads = Reads()
    let parser = DiskListParser(
      showInternalDisks: true,
      fileSystemUsage: { path in
        reads.lock.withLock { reads.paths.append(path) }
        return .usage(total: 100, free: 50)
      },
      classifyDisksWithoutInfo: { _ in ["disk7": .external] })
    let result = parse(parser)

    // APFS volumes have CapacityInUse and disk7 is not mounted: only the
    // NTFS volume of disk6 needs statfs.
    XCTAssertEqual(reads.paths, ["/Volumes/Samsung_T5"])
    XCTAssertFalse(result.usageTimedOut)
  }

  func testUnmountedVolumeHasNoUsage() throws {
    let oneTouch = try XCTUnwrap(parse(parser()).disks.first { $0.id == "disk7" })
    let volume = try XCTUnwrap(oneTouch.partitions.first)

    XCTAssertFalse(volume.isMounted)
    XCTAssertNil(volume.usedBytes)
    XCTAssertNotNil(volume.totalSize)
    XCTAssertEqual(oneTouch.usagePercentage, 0)
  }

  func testDiskWithoutInfoUsesFallbackClassification() throws {
    let external = try XCTUnwrap(parse(parser()).disks.first { $0.id == "disk7" })
    XCTAssertEqual(external.type, .physical)
    XCTAssertEqual(
      external.connectionType, NSLocalizedString("Unknown", comment: "Unknown connection type"))

    let image = try XCTUnwrap(
      parse(parser(fallback: ["disk7": .diskImage])).disks.first { $0.id == "disk7" })
    XCTAssertEqual(image.type, .diskImage)
  }

  func testUnclassifiedDiskIsListedAsUnverifiedAndNotRemovable() throws {
    let result = parse(parser(fallback: [:]))
    let unknown = try XCTUnwrap(result.disks.first { $0.id == "disk7" })

    XCTAssertEqual(result.unverifiedDiskIDs, ["disk7"])
    XCTAssertEqual(unknown.type, .internalDisk)
    XCTAssertFalse(unknown.isRemovable)
  }

  func testDiskKnownInternalWithoutInfoIsHidden() {
    let result = parse(parser(fallback: ["disk7": .internalDisk]))
    XCTAssertEqual(result.disks.map(\.id), ["disk6"])
    XCTAssertTrue(result.unverifiedDiskIDs.isEmpty)
  }

  func testIgnoredVolumeIsDroppedAndProtectedVolumeIsMarked() {
    let samsungID = "NONE-F6664668-1958-3938-9449-2C1A72F37580"
    let oneTouchID = "NONE-EC5A6C68-26FA-39D5-BCF9-55C4A68DC4F9"
    let result = parse(
      parser(filters: .init(ignoredIDs: [samsungID], protectedIDs: [oneTouchID])))

    // A disk left without volumes is not listed.
    XCTAssertEqual(result.disks.map(\.id), ["disk7"])
    XCTAssertEqual(result.disks.first?.partitions.first?.isProtected, true)
  }

  // MARK: - Containers across several physical stores

  /// A Fusion-style container backed by disk10s2 (SSD) and disk11s2 (HDD).
  private func fusionDisks() throws -> [[String: Any]] {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "fusionDisks", withExtension: "plist"))
    let plist = try XCTUnwrap(
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
    return try XCTUnwrap(DiskListParser.allDisksAndPartitions(in: plist))
  }

  func testContainerOnTwoPhysicalStoresIsListedOnce() throws {
    let result = parser().parse(
      allDisksAndPartitions: try fusionDisks(), rootInfo: [:], unclassifiedDiskIDs: [])
    XCTAssertEqual(result.disks.map(\.id), ["disk10", "disk11"])
    let containers = result.disks.flatMap(\.containers)
    XCTAssertEqual(containers.map(\.id), ["disk12"])
    XCTAssertEqual(result.disks.first { $0.id == "disk10" }?.containers.count, 1)
    XCTAssertEqual(result.disks.first { $0.id == "disk11" }?.containers.count, 0)
    let volumeIDs = result.disks.flatMap(\.containers).flatMap(\.volumes).map(\.id)
    XCTAssertEqual(Set(volumeIDs).count, volumeIDs.count)
  }

  func testContainerOnTwoStoresCountsItsUsageOnce() throws {
    let result = parser().parse(
      allDisksAndPartitions: try fusionDisks(), rootInfo: [:], unclassifiedDiskIDs: [])
    let containerUsed = result.disks.flatMap(\.containers).flatMap(\.volumes)
      .reduce(Int64(0)) { $0 + ($1.usedBytes ?? 0) }
    XCTAssertEqual(containerUsed, 300_000_000_000)
  }

  // MARK: - Several volumes in one container

  /// External disk20 with a 500 GB APFS container (disk21) holding "Backup"
  /// (300 GB used) and "Data" (100 GB used); diskutil gives each volume the
  /// container size.
  private func twoVolumeDisks() -> [[String: Any]] {
    let size: Int64 = 500_000_000_000
    func volume(_ n: Int, _ name: String, used: Int64) -> [String: Any] {
      [
        "DeviceIdentifier": "disk21s\(n)", "VolumeName": name, "Size": size,
        "CapacityInUse": used, "MountPoint": "/Volumes/\(name)",
        "VolumeUUID": "2B000000-0000-4000-8000-00000000002\(n)",
      ]
    }
    return [
      [
        "DeviceIdentifier": "disk20", "Content": "GUID_partition_scheme", "Size": size + 1,
        "Partitions": [["DeviceIdentifier": "disk20s2", "Content": "Apple_APFS", "Size": size]],
      ],
      [
        "DeviceIdentifier": "disk21", "Content": "Apple_APFS_Container", "Size": size,
        "Partitions": [], "APFSPhysicalStores": [["DeviceIdentifier": "disk20s2"]],
        "APFSVolumes": [
          volume(1, "Backup", used: 300_000_000_000), volume(2, "Data", used: 100_000_000_000),
        ],
      ],
    ]
  }

  func testVolumesOfOneContainerShowTheContainerFreeSpace() throws {
    let result = parser().parse(
      allDisksAndPartitions: twoVolumeDisks(), rootInfo: [:], unclassifiedDiskIDs: [])
    let volumes = try XCTUnwrap(result.disks.first?.containers.first?.volumes)
    XCTAssertEqual(volumes.map(\.name), ["Backup", "Data"])
    for volume in volumes {
      XCTAssertEqual(try XCTUnwrap(volume.usagePercentage), 0.8, accuracy: 0.0001)
      XCTAssertEqual(volume.freeSpace?.hasPrefix("100"), true, volume.freeSpace ?? "nil")
      XCTAssertNotNil(LowSpaceRules.warning(for: volume, on: .physical, threshold: 0.8))
    }
    // Disk totals still count each volume once.
    XCTAssertEqual(volumes.compactMap(\.usedBytes), [300_000_000_000, 100_000_000_000])
  }

  func testContainerUsageLeavesSingleVolumesAndErrorsAlone() {
    let single = [volume(usedBytes: 300)]
    XCTAssertEqual(DiskListParser.apfsContainerUsage(size: 1_000, volumes: single), single)

    let failed = volume(storageError: "boom")
    let shared = DiskListParser.apfsContainerUsage(
      size: 1_000, volumes: [volume(usedBytes: 900), volume(usedBytes: 400), failed])
    XCTAssertEqual(shared[0].usagePercentage, 1.0)
    XCTAssertEqual(shared[1].usagePercentage, 1.0)
    XCTAssertEqual(shared[2], failed)
    XCTAssertEqual(shared[1].usedBytes, 400)
  }

  func testIgnoredVolumeStillCountsTowardContainerFreeSpace() throws {
    let all = parser().parse(
      allDisksAndPartitions: twoVolumeDisks(), rootInfo: [:], unclassifiedDiskIDs: [])
    let dataID = try XCTUnwrap(all.disks.first?.containers.first?.volumes.last?.ignoreIdentifier)

    let result = parser(filters: .init(ignoredIDs: [dataID])).parse(
      allDisksAndPartitions: twoVolumeDisks(), rootInfo: [:], unclassifiedDiskIDs: [])
    let volumes = try XCTUnwrap(result.disks.first?.containers.first?.volumes)
    XCTAssertEqual(volumes.map(\.name), ["Backup"])
    let backup = try XCTUnwrap(volumes.first)
    // 400 GB of 500 GB used by both volumes, as diskutil reports.
    XCTAssertEqual(try XCTUnwrap(backup.usagePercentage), 0.8, accuracy: 0.0001)
    XCTAssertEqual(backup.freeSpace?.hasPrefix("100"), true, backup.freeSpace ?? "nil")
    XCTAssertEqual(backup.usedBytes, 300_000_000_000)
    // The disk total counts the ignored volume too.
    let disk = try XCTUnwrap(result.disks.first)
    XCTAssertEqual(try XCTUnwrap(disk.usagePercentage), 0.8, accuracy: 0.0001)
    XCTAssertEqual(disk.freeSpace, all.disks.first?.freeSpace)
    XCTAssertEqual(disk.usedSpace, all.disks.first?.usedSpace)
  }

  // MARK: - Built-in card reader

  /// `diskutil info` of an SD card in a MacBook's slot (synthetic): the
  /// reader is built in, so `Internal` is true.
  private func sdCardInfo() throws -> [String: Any] {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "diskutilInfoSDCard", withExtension: "plist"))
    return try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])
  }

  func testCardInBuiltInReaderIsExternal() throws {
    let sdCardInfo = try sdCardInfo()
    XCTAssertFalse(DiskListParser.isInternalDisk(sdCardInfo))
    XCTAssertFalse(DiskListParser.isInternalDisk(["Internal": true, "BusProtocol": "SD"]))
    XCTAssertFalse(DiskListParser.isInternalDisk(["Internal": true, "Ejectable": true]))
    XCTAssertTrue(
      DiskListParser.isInternalDisk([
        "Internal": true, "RemovableMedia": false, "Ejectable": false,
        "BusProtocol": "Apple Fabric",
      ]))
    XCTAssertFalse(DiskListParser.isInternalDisk(["Internal": false]))

    let result = parser().parse(
      allDisksAndPartitions: twoVolumeDisks(), rootInfo: ["disk20": sdCardInfo],
      unclassifiedDiskIDs: [])
    let card = try XCTUnwrap(result.disks.first)
    XCTAssertEqual(card.type, .physical)
    XCTAssertTrue(card.isRemovable)
    XCTAssertEqual(card.connectionType, "Secure Digital")
  }

  func testDiskArbitrationFallbackTreatsCardReaderMediaAsExternal() throws {
    let card: [String: Any] = [
      kDADiskDescriptionDeviceInternalKey as String: true,
      kDADiskDescriptionMediaRemovableKey as String: true,
      kDADiskDescriptionMediaEjectableKey as String: true,
      kDADiskDescriptionDeviceProtocolKey as String: "Secure Digital",
    ]
    let cardInfo = try XCTUnwrap(DiskListParser.diskutilStyleInfo(fromDiskArbitration: card))
    XCTAssertFalse(DiskListParser.isInternalDisk(cardInfo))

    let ssd: [String: Any] = [
      kDADiskDescriptionDeviceInternalKey as String: true,
      kDADiskDescriptionMediaRemovableKey as String: false,
      kDADiskDescriptionMediaEjectableKey as String: false,
      kDADiskDescriptionDeviceProtocolKey as String: "Apple Fabric",
    ]
    let ssdInfo = try XCTUnwrap(DiskListParser.diskutilStyleInfo(fromDiskArbitration: ssd))
    XCTAssertTrue(DiskListParser.isInternalDisk(ssdInfo))
    XCTAssertNil(DiskListParser.diskutilStyleInfo(fromDiskArbitration: [:]))
  }

  // MARK: - Helpers

  func testFindAPFSContainerMatchesPhysicalStore() {
    XCTAssertEqual(
      DiskListParser.findAPFSContainer(forStore: "disk0s2", in: allDisks)?["DeviceIdentifier"]
        as? String, "disk3")
    XCTAssertNil(DiskListParser.findAPFSContainer(forStore: "disk6s1", in: allDisks))
  }

  func testParentDiskStatsSumsUsedBytesAndCapsAtFull() {
    let stats = DiskListParser.parentDiskStats(
      totalBytes: 1_000, volumes: [volume(usedBytes: 300), volume(usedBytes: 200)])
    XCTAssertEqual(stats.percentage, 0.5)
    XCTAssertNil(stats.error)
    XCTAssertNotNil(stats.total)

    let overfull = DiskListParser.parentDiskStats(
      totalBytes: 1_000, volumes: [volume(usedBytes: 900), volume(usedBytes: 400)])
    XCTAssertEqual(overfull.percentage, 1.0)
  }

  func testParentDiskStatsWithoutSizeOrWithErrors() {
    let noSize = DiskListParser.parentDiskStats(totalBytes: 0, volumes: [volume(usedBytes: 1)])
    XCTAssertNil(noSize.total)
    XCTAssertNil(noSize.percentage)

    let failed = DiskListParser.parentDiskStats(
      totalBytes: 1_000, volumes: [volume(usedBytes: 1), volume(storageError: "boom")])
    XCTAssertEqual(failed.error, "boom")
    XCTAssertNil(failed.total)
    XCTAssertNil(failed.percentage)
  }

  func testConnectionInfoForImagesRAIDAndInternalDisks() {
    let image = DiskListParser.connectionInfo(
      from: ["VirtualOrPhysical": "Virtual", "BusProtocol": "Disk Image"], isInternal: false)
    XCTAssertEqual(image.diskType, .diskImage)
    XCTAssertEqual(image.type, NSLocalizedString("Disk Image", comment: "Disk Image"))

    let raid = DiskListParser.connectionInfo(
      from: ["RAIDMaster": true, "VirtualOrPhysical": "Virtual"], isInternal: false)
    XCTAssertEqual(raid.diskType, .physical)
    XCTAssertEqual(raid.type, NSLocalizedString("Apple RAID", comment: "Apple RAID"))

    let internalDisk = DiskListParser.connectionInfo(
      from: ["BusProtocol": "PCI-Express"], isInternal: true)
    XCTAssertEqual(internalDisk.diskType, .internalDisk)
    XCTAssertEqual(internalDisk.type, "PCI-Express")
  }

  func testFallbackConnectionInfoNeverMakesUnknownDisksRemovable() {
    XCTAssertEqual(DiskListParser.fallbackConnectionInfo(for: .external).diskType, .physical)
    XCTAssertEqual(DiskListParser.fallbackConnectionInfo(for: .diskImage).diskType, .diskImage)
    XCTAssertEqual(
      DiskListParser.fallbackConnectionInfo(for: .internalDisk).diskType, .internalDisk)
    XCTAssertEqual(DiskListParser.fallbackConnectionInfo(for: .unknown).diskType, .internalDisk)
  }

  private func volume(usedBytes: Int64? = nil, storageError: String? = nil) -> Volume {
    Volume(
      id: UUID().uuidString, deviceIdentifier: "disk9s1", diskUUID: nil, name: "Test",
      isMounted: true, mountPoint: "/Volumes/Test", freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: usedBytes, fileSystemType: "apfs", usagePercentage: nil,
      category: .user, isProtected: false, snapshots: [], storageError: storageError)
  }

  // MARK: - Duplicate VolumeUUID

  private func volume(_ id: String, device: String, protected: Bool = false) -> Volume {
    var v = Volume(
      id: id, deviceIdentifier: device, diskUUID: "AAAAAAAA-0000-4000-8000-000000000001",
      name: "bootfs", isMounted: true, mountPoint: nil, freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: nil, fileSystemType: nil, usagePercentage: nil,
      category: .user, isProtected: protected, snapshots: [], storageError: nil)
    v.isLowSpaceMuted = protected
    return v
  }

  private func disk(_ id: String, _ volumes: [Volume]) -> PhysicalDisk {
    PhysicalDisk(
      id: id, diskUUID: nil, connectionType: "USB", name: id, totalSize: nil, freeSpace: nil,
      usedSpace: nil, usagePercentage: nil, type: .physical, isRAIDSet: false,
      partitions: volumes, containers: [], storageError: nil)
  }

  func testDuplicateVolumeUUIDsGetDistinctIdsAndNoCompositeId() throws {
    let uuid = "11111111-2222-4333-8444-555555555555"
    let other = "99999999-2222-4333-8444-555555555555"
    let result = DiskListParser.disambiguatingDuplicateUUIDs([
      disk("disk4", [volume(uuid, device: "disk4s1", protected: true)]),
      disk("disk5", [volume(uuid, device: "disk5s1"), volume(other, device: "disk5s2")]),
    ])
    let all = result.flatMap(\.allVolumes)
    XCTAssertEqual(all.map(\.id), ["\(uuid)#disk4s1", "\(uuid)#disk5s1", other])
    XCTAssertEqual(Set(all.map(\.id)).count, 3)
    XCTAssertNil(all[0].compositeId)
    XCTAssertNil(all[1].compositeId)
    XCTAssertTrue(all[0].isDuplicateUUID)
    XCTAssertFalse(all[0].isProtected)
    XCTAssertFalse(all[0].isLowSpaceMuted)
    XCTAssertNotNil(all[2].compositeId)
    XCTAssertFalse(all[2].isDuplicateUUID)
  }

  func testUniqueVolumeUUIDKeepsItsId() {
    let uuid = "11111111-2222-4333-8444-555555555555"
    let input = [disk("disk4", [volume(uuid, device: "disk4s1")])]
    let result = DiskListParser.disambiguatingDuplicateUUIDs(input)
    XCTAssertEqual(result, input)
    XCTAssertNotNil(result[0].partitions[0].compositeId)
  }

  func testDeviceIdentifierIdsAreNotTreatedAsDuplicates() {
    let input = [disk("disk4", [volume("disk4s1", device: "disk4s1")])]
    XCTAssertEqual(DiskListParser.disambiguatingDuplicateUUIDs(input), input)
  }

  // MARK: - Detaching a disk image after its last volume unmounts

  func testDetachCompletesOnlyAfterTheEjectFinishes() {
    var finishEject: ((Result<Void, Error>) -> Void)?
    var results: [Result<Void, Error>] = []
    var alerts: Bool?
    DriveManager.detach(
      disk("disk9", []), allowsErrorAlerts: false, completion: { results.append($0) },
      using: { _, allowsAlerts, done in
        alerts = allowsAlerts
        finishEject = done
      })
    XCTAssertTrue(results.isEmpty)
    XCTAssertEqual(alerts, false)
    finishEject?(.success(()))
    XCTAssertEqual(results.count, 1)
    if case .failure = results[0] { XCTFail("expected success") }
  }

  func testDetachFailureIsReported() {
    struct Boom: Error {}
    var result: Result<Void, Error>?
    DriveManager.detach(
      disk("disk9", []), allowsErrorAlerts: false, completion: { result = $0 },
      using: { _, _, done in done(.failure(Boom())) })
    guard case .failure(let error)? = result else { return XCTFail("expected failure") }
    XCTAssertTrue(error is Boom)
  }
}
