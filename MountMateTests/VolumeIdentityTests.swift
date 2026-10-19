//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeIdentityTests: XCTestCase {
  private func volume(id: String, deviceIdentifier: String = "disk4s1", diskUUID: String?)
    -> Volume
  {
    Volume(
      id: id, deviceIdentifier: deviceIdentifier, diskUUID: diskUUID, name: "Test",
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  private let volumeUUID = "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"
  private let diskUUID = "0A1B2C3D-0000-1111-2222-333344445555"

  func testVolumeWithUUIDHasCompositeID() {
    let v = volume(id: volumeUUID, diskUUID: diskUUID)
    XCTAssertEqual(v.compositeId, "\(diskUUID)-\(volumeUUID)")
    XCTAssertEqual(v.managedVolumeInfo?.id, v.compositeId)
  }

  func testMissingDiskUUIDFallsBackToNONE() {
    let v = volume(id: volumeUUID, diskUUID: nil)
    XCTAssertEqual(v.compositeId, "NONE-\(volumeUUID)")
    XCTAssertEqual(v.managedVolumeInfo?.diskUUID, "NONE")
  }

  func testVolumeWithoutUUIDHasNoIdentity() {
    // DriveManager uses the device identifier as `id` when there is no UUID.
    let v = volume(id: "disk4s1", deviceIdentifier: "disk4s1", diskUUID: nil)
    XCTAssertNil(v.compositeId)
    XCTAssertNil(v.managedVolumeInfo)
    XCTAssertNil(v.stableVolumeUUID)
  }

  func testNonUUIDIdentifierHasNoIdentity() {
    let v = volume(id: "not-a-uuid", deviceIdentifier: "disk4s1", diskUUID: diskUUID)
    XCTAssertNil(v.compositeId)
    XCTAssertNil(v.managedVolumeInfo)
  }

  // MARK: - Ignore identity

  func testIgnoreIdentifierMatchesCompositeIDForVolumesWithUUID() {
    let v = volume(id: volumeUUID, diskUUID: diskUUID)
    XCTAssertEqual(v.ignoreIdentifier, v.compositeId)
    XCTAssertEqual(v.ignoreVolumeInfo, v.managedVolumeInfo)
  }

  func testPartitionWithoutVolumeUUIDIsIgnoredByItsDiskUUID() {
    let v = volume(id: "disk4s1", deviceIdentifier: "disk4s1", diskUUID: diskUUID)
    XCTAssertNil(v.compositeId)
    XCTAssertEqual(v.ignoreIdentifier, "\(diskUUID)-\(diskUUID)")
    XCTAssertEqual(v.ignoreVolumeInfo?.volumeUUID, diskUUID)
  }

  func testPartitionWithoutAnyUUIDCannotBeIgnored() {
    let v = volume(id: "disk4s1", deviceIdentifier: "disk4s1", diskUUID: nil)
    XCTAssertNil(v.ignoreIdentifier)
  }

  func testIgnoredEntryMigration() {
    let entries = [
      ManagedVolumeInfo(volumeUUID: volumeUUID, diskUUID: diskUUID, name: "Data"),
      // Old key of a partition without a volume UUID: migrated.
      ManagedVolumeInfo(volumeUUID: "disk4s1", diskUUID: diskUUID, name: "MSR"),
      // Already migrated: kept, and the duplicate from above is dropped.
      ManagedVolumeInfo(volumeUUID: diskUUID, diskUUID: diskUUID, name: "MSR"),
      // Neither UUID: dropped.
      ManagedVolumeInfo(volumeUUID: "disk5s2", diskUUID: "NONE", name: "Swap"),
    ]
    let migrated = PersistenceManager.migratedIgnoredEntries(entries)
    XCTAssertEqual(
      migrated.map(\.id), ["\(diskUUID)-\(volumeUUID)", "\(diskUUID)-\(diskUUID)"])
    XCTAssertEqual(PersistenceManager.migratedIgnoredEntries(migrated), migrated)
  }
}
