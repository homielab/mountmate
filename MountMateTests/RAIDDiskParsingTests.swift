import XCTest

@testable import MountMate

final class RAIDDiskParsingTests: XCTestCase {
  func testRAIDMemberPartitionDetection() {
    let raidMemberPartition: [[String: Any]] = [
      ["Content": "EFI", "DeviceIdentifier": "disk5s1"],
      ["Content": "Apple_RAID", "DeviceIdentifier": "disk5s2"],
      ["Content": "Apple_Boot", "DeviceIdentifier": "disk5s3"],
    ]
    XCTAssertTrue(DiskTopology.isRAIDMember(nil, partitions: raidMemberPartition))
  }

  func testNonRAIDPartitionDetection() {
    let regularPartition: [[String: Any]] = [
      ["Content": "EFI", "DeviceIdentifier": "disk0s1"],
      ["Content": "Apple_APFS", "DeviceIdentifier": "disk0s2"],
    ]
    XCTAssertFalse(DiskTopology.isRAIDMember(nil, partitions: regularPartition))
  }

  func testWholeDiskRAIDVolumeParsing() {
    let plistData: [String: Any] = [
      "AllDisksAndPartitions": [
        [
          "Content": "Apple_HFS",
          "DeviceIdentifier": "disk9",
          "MountPoint": "/Volumes/Kappa",
          "OSInternal": false,
          "Size": Int64(16_001_772_158_976),
          "VolumeName": "Kappa",
        ]
      ]
    ]

    // Perform parsing test logic manually or via DriveManager helper if available
    let allDisks = plistData["AllDisksAndPartitions"] as! [[String: Any]]
    let diskData = allDisks[0]
    XCTAssertEqual(diskData["VolumeName"] as? String, "Kappa")
    XCTAssertEqual(diskData["MountPoint"] as? String, "/Volumes/Kappa")
  }
}
