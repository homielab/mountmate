//  Created by homielab.com

import XCTest

@testable import MountMate

final class RenamedVolumeNamesTests: XCTestCase {
  private let uuidA = "11111111-1111-1111-1111-111111111111"
  private let uuidB = "22222222-2222-2222-2222-222222222222"
  private let disk = "99999999-9999-9999-9999-999999999999"

  private func volume(_ id: String, name: String) -> Volume {
    Volume(
      id: id, deviceIdentifier: "disk9s1", diskUUID: disk, name: name,
      isMounted: true, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: "exfat", usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  private func info(_ uuid: String, _ name: String) -> ManagedVolumeInfo {
    ManagedVolumeInfo(volumeUUID: uuid, diskUUID: disk, name: name)
  }

  func testChangedNameIsUpdated() {
    let result = PersistenceManager.renamed(
      [info(uuidA, "Backup")], using: [volume(uuidA, name: "Archive")])
    XCTAssertEqual(result, [info(uuidA, "Archive")])
  }

  func testSameNameReturnsNil() {
    XCTAssertNil(
      PersistenceManager.renamed(
        [info(uuidA, "Backup")], using: [volume(uuidA, name: "Backup")]))
  }

  func testAbsentVolumeKeepsLastKnownName() {
    XCTAssertNil(PersistenceManager.renamed([info(uuidA, "Backup")], using: []))
    XCTAssertNil(
      PersistenceManager.renamed(
        [info(uuidA, "Backup")], using: [volume(uuidB, name: "Other")]))
  }

  func testDifferentIDsDoNotMix() {
    let result = PersistenceManager.renamed(
      [info(uuidA, "A"), info(uuidB, "B")], using: [volume(uuidB, name: "B2")])
    XCTAssertEqual(result, [info(uuidA, "A"), info(uuidB, "B2")])
  }

  func testIdleEntryKeepsMinutes() {
    let entry = IdleUnmountVolume(volumeUUID: uuidA, diskUUID: disk, name: "Old", minutes: 15)
    let result = PersistenceManager.renamed([entry], using: [volume(uuidA, name: "New")])
    XCTAssertEqual(result?.first?.name, "New")
    XCTAssertEqual(result?.first?.minutes, 15)
  }

  func testCustomMountPointIsMatchedByDiskAndVolume() {
    let entry = VolumeCustomMountPoint(
      volumeUUID: uuidA, backingDiskIdentifier: disk, name: "Old", mountPoint: "/Volumes/x")
    let result = PersistenceManager.renamed([entry], using: [volume(uuidA, name: "New")])
    XCTAssertEqual(result?.first?.name, "New")
    XCTAssertEqual(result?.first?.mountPoint, "/Volumes/x")
    XCTAssertNil(
      PersistenceManager.renamed([entry], using: [volume(uuidA, name: "Old")]))
  }
}
