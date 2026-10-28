//  Created by homielab.com

import XCTest

@testable import MountMate

/// Which keep-alive volumes a reconnect sweep looks at.
final class KeepAliveCandidatesTests: XCTestCase {
  private let uuidA = "11111111-1111-1111-1111-111111111111"
  private let uuidB = "22222222-2222-2222-2222-222222222222"
  private let uuidC = "33333333-3333-3333-3333-333333333333"

  private func volume(_ id: String, disk: String, mounted: Bool = false) -> Volume {
    Volume(
      id: id, deviceIdentifier: "\(disk)s1", diskUUID: "DISK-\(disk)", name: "Vol",
      isMounted: mounted, mountPoint: mounted ? "/Volumes/Vol" : nil, freeSpace: nil,
      totalSize: nil, usedSpace: nil, usedBytes: nil, fileSystemType: "apfs",
      usagePercentage: nil, category: .user, isProtected: false, snapshots: [])
  }

  private func disk(_ id: String, _ volumes: [Volume]) -> PhysicalDisk {
    PhysicalDisk(
      id: id, diskUUID: "DISK-\(id)", connectionType: "USB", name: "Disk", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: .physical, isRAIDSet: false,
      partitions: volumes, containers: [], storageError: nil)
  }

  private var disks: [PhysicalDisk] {
    [
      disk("disk4", [volume(uuidA, disk: "disk4"), volume(uuidC, disk: "disk4")]),
      disk("disk5", [volume(uuidB, disk: "disk5")]),
    ]
  }

  private var allIDs: Set<String> {
    Set(disks.flatMap(\.allVolumes).compactMap(\.compositeId))
  }

  private func candidates(
    isStale: Bool = false, unverified: Set<String> = [], keepAliveIDs: Set<String>? = nil,
    isBlocked: (Volume) -> Bool = { _ in false }
  ) -> [String] {
    KeepAliveManager.volumeCandidates(
      disks: disks, isStale: isStale, unverifiedDiskIDs: unverified,
      keepAliveIDs: keepAliveIDs ?? allIDs, isBlocked: isBlocked
    ).map(\.id)
  }

  func testNormalListKeepsKeepAliveVolumesInOrder() {
    XCTAssertEqual(candidates(), [uuidA, uuidC, uuidB])
  }

  func testOnlyKeepAliveVolumesAreCandidates() {
    XCTAssertEqual(candidates(keepAliveIDs: ["DISK-disk5-\(uuidB)"]), [uuidB])
  }

  func testBlockedVolumeIsSkipped() {
    XCTAssertEqual(candidates(isBlocked: { $0.id == self.uuidC }), [uuidA, uuidB])
  }

  func testStaleListGivesNoCandidates() {
    XCTAssertEqual(candidates(isStale: true), [])
  }

  func testUnverifiedDiskIsSkipped() {
    XCTAssertEqual(candidates(unverified: ["disk4"]), [uuidB])
  }

  func testVolumeWithoutStableIDIsSkipped() {
    let plain = disk("disk6", [volume("disk6s1", disk: "disk6")])
    XCTAssertTrue(
      KeepAliveManager.volumeCandidates(
        disks: [plain], isStale: false, unverifiedDiskIDs: [], keepAliveIDs: allIDs,
        isBlocked: { _ in false }
      ).isEmpty)
  }
}
