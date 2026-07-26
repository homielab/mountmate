import XCTest
@testable import MountMate

final class RAIDDiskParsingTests: XCTestCase {
  func testRAIDMemberPartitionDetection() {
    let raidMemberPartition: [[String: Any]] = [
      ["Content": "EFI", "DeviceIdentifier": "disk5s1"],
      ["Content": "Apple_RAID", "DeviceIdentifier": "disk5s2"],
      ["Content": "Apple_Boot", "DeviceIdentifier": "disk5s3"]
    ]
    XCTAssertTrue(DiskTopology.isRAIDMember(nil, partitions: raidMemberPartition))
  }

  func testNonRAIDPartitionDetection() {
    let regularPartition: [[String: Any]] = [
      ["Content": "EFI", "DeviceIdentifier": "disk0s1"],
      ["Content": "Apple_APFS", "DeviceIdentifier": "disk0s2"]
    ]
    XCTAssertFalse(DiskTopology.isRAIDMember(nil, partitions: regularPartition))
  }
}
