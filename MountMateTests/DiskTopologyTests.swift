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
}
