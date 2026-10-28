//  Created by homielab.com

import XCTest

@testable import MountMate

/// The number shown next to the menu bar icon and spoken by VoiceOver.
final class MountedCountTests: XCTestCase {
  private func volume(
    _ id: String, mounted: Bool = true, category: DriveCategory = .user, protected: Bool = false
  ) -> Volume {
    Volume(
      id: id, deviceIdentifier: "disk9s\(id)", diskUUID: nil, name: "Vol \(id)",
      isMounted: mounted, mountPoint: mounted ? "/Volumes/\(id)" : nil, freeSpace: nil,
      totalSize: nil, usedSpace: nil, usedBytes: nil, fileSystemType: "apfs",
      usagePercentage: nil, category: category, isProtected: protected, snapshots: [])
  }

  private func disk(
    _ id: String = "disk9", type: PhysicalDiskType = .physical, partitions: [Volume] = [],
    containers: [APFSContainer] = []
  ) -> PhysicalDisk {
    PhysicalDisk(
      id: id, diskUUID: nil, connectionType: "USB", name: "Disk", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: type, isRAIDSet: false,
      partitions: partitions, containers: containers, storageError: nil)
  }

  private func total(_ disks: [PhysicalDisk], network: Int = 0, manual: Int = 0) -> Int {
    MountedCount.total(disks: disks, networkMountedCount: network, manualCount: manual)
  }

  func testNothingMountedIsZero() {
    XCTAssertEqual(total([]), 0)
  }

  func testAddsMountedSavedSharesAndManualShares() {
    XCTAssertEqual(total([disk(partitions: [volume("1")])], network: 2, manual: 3), 6)
    XCTAssertEqual(total([], network: 1, manual: 0), 1)
  }

  func testInternalDiskCountsItsMountedUserVolumesButNotSystemOnes() {
    let internalDisk = disk(
      "disk0", type: .internalDisk,
      partitions: [volume("efi", category: .system)],
      containers: [
        APFSContainer(id: "disk3", volumes: [volume("data"), volume("vm", category: .system)])
      ])
    XCTAssertEqual(total([internalDisk]), 1)
  }

  func testProtectedVolumeIsNotCounted() {
    XCTAssertEqual(total([disk(partitions: [volume("1"), volume("2", protected: true)])]), 1)
  }

  func testUnmountedVolumeIsNotCounted() {
    XCTAssertEqual(total([disk(partitions: [volume("1"), volume("2", mounted: false)])]), 1)
  }

  func testAPFSContainerVolumesAreCountedLikePartitions() {
    let external = disk(
      partitions: [volume("p1")],
      containers: [
        APFSContainer(id: "disk10", volumes: [volume("a"), volume("b")]),
        APFSContainer(id: "disk11", volumes: [volume("c", mounted: false)]),
      ])
    XCTAssertEqual(total([external]), 3)
  }

  func testLonePartitionAndDiskImagesAreCounted() {
    let lone = disk("disk6", partitions: [volume("ntfs")])
    let image = disk("disk12", type: .diskImage, partitions: [volume("dmg")])
    let empty = disk("disk13")
    XCTAssertEqual(total([lone, image, empty]), 2)
  }

  /// Ignored volumes are dropped while parsing, so they never reach the count.
  func testIgnoredVolumeIsNotCounted() throws {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "testDisks", withExtension: "plist"))
    let plist = try XCTUnwrap(
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
    let allDisks = try XCTUnwrap(DiskListParser.allDisksAndPartitions(in: plist))
    let rootInfo: [String: [String: Any]] = [
      "disk6": [
        "Internal": false, "BusProtocol": "USB",
        "DiskUUID": "6A1B0C2D-0000-4000-8000-000000000006",
      ]
    ]
    func parse(ignoring ignored: Set<String>) -> [PhysicalDisk] {
      DiskListParser(
        filters: .init(ignoredIDs: ignored), showInternalDisks: false,
        fileSystemUsage: { _ in .usage(total: 100, free: 50) },
        classifyDisksWithoutInfo: { ids in ids.contains("disk7") ? ["disk7": .external] : [:] }
      ).parse(allDisksAndPartitions: allDisks, rootInfo: rootInfo, unclassifiedDiskIDs: ["disk7"])
        .disks
    }

    let shown = parse(ignoring: [])
    let samsung = try XCTUnwrap(shown.first { $0.id == "disk6" }?.partitions.first)
    XCTAssertTrue(samsung.isMounted)
    let ignoreID = try XCTUnwrap(samsung.ignoreIdentifier)

    XCTAssertEqual(total(parse(ignoring: [ignoreID])), total(shown) - 1)
  }
}
