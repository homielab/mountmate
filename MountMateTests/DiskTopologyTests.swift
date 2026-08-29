import XCTest

@testable import MountMate

final class DiskTopologyTests: XCTestCase {
  func testRegularExternalDiskIsNotRAID() {
    XCTAssertFalse(DiskTopology.isRAIDMaster(["BusProtocol": "USB"]))
    XCTAssertFalse(DiskTopology.isRAIDMember(["BusProtocol": "USB"]))
  }

  func testRAIDMasterIsNotTreatedAsAMember() {
    let master: [String: Any] = ["RAIDMaster": true, "VirtualOrPhysical": "Virtual"]

    XCTAssertTrue(DiskTopology.isRAIDMaster(master))
    XCTAssertFalse(DiskTopology.isRAIDMember(master))
  }

  func testRAIDMemberWithMasterIdentifierIsHidden() {
    XCTAssertTrue(DiskTopology.isRAIDMember(["RAIDMaster": "disk8"]))
  }

  func testTimeMachineBackupRoleIsRecognized() {
    XCTAssertTrue(DiskTopology.isTimeMachineVolume(["APFSVolumeRole": "Backup"]))
    XCTAssertFalse(DiskTopology.isTimeMachineVolume(["APFSVolumeRole": "Data"]))
  }

  func testSealedSnapshotDeviceIsDetected() {
    XCTAssertTrue(DiskTopology.isSealedSnapshotDevice("disk5s1s1"))
    XCTAssertTrue(DiskTopology.isSealedSnapshotDevice("disk12s3s2"))
  }

  func testRegularDevicesAreNotSealedSnapshots() {
    XCTAssertFalse(DiskTopology.isSealedSnapshotDevice("disk5s1"))
    XCTAssertFalse(DiskTopology.isSealedSnapshotDevice("disk5"))
    XCTAssertFalse(DiskTopology.isSealedSnapshotDevice("disk5s1s1extra"))
    XCTAssertFalse(DiskTopology.isSealedSnapshotDevice(""))
  }

  func testWholeDiskVolumeDetection() {
    // Real whole-disk media always exposes a volume name or mount point.
    XCTAssertTrue(
      DiskTopology.hasWholeDiskVolume(
        ["DeviceIdentifier": "disk9", "Size": 1_000, "VolumeName": "Kappa"]))
    XCTAssertTrue(
      DiskTopology.hasWholeDiskVolume(
        ["DeviceIdentifier": "disk9", "Size": 1_000, "MountPoint": "/Volumes/Kappa"]))
    // Bare OS-internal devices (e.g. cryptex RAM disks) have neither.
    XCTAssertFalse(
      DiskTopology.hasWholeDiskVolume(["DeviceIdentifier": "disk7", "Size": 1_000, "Content": ""]))
    XCTAssertFalse(
      DiskTopology.hasWholeDiskVolume(
        ["DeviceIdentifier": "disk7", "Size": 1_000, "VolumeName": ""]))
  }
}
