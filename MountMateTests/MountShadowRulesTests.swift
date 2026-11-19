//  Created by homielab.com

import XCTest

@testable import MountMate

final class MountShadowRulesTests: XCTestCase {
  private let uuid = "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"
  private let otherUUID = "0A1B2C3D-0000-1111-2222-333344445555"

  private func record(
    _ path: String, uuid: String? = nil, isMountPoint: Bool = true
  ) -> MountShadowRules.MountRecord {
    MountShadowRules.MountRecord(path: path, uuid: uuid, isMountPoint: isMountPoint)
  }

  private func shadow(
    name: String = "Backup", registeredUUID: String? = nil,
    records: [MountShadowRules.MountRecord]
  ) -> MountShadowRules.Shadow? {
    MountShadowRules.shadow(
      expectedName: name, registeredUUID: registeredUUID ?? uuid, records: records)
  }

  // MARK: - Suffix parsing

  func testNumericSuffixParsesOnlyExactDigitSuffixes() {
    XCTAssertEqual(MountShadowRules.numericSuffix(of: "Backup", at: "/Volumes/Backup 1"), 1)
    XCTAssertEqual(MountShadowRules.numericSuffix(of: "Backup", at: "/Volumes/Backup 10"), 10)
    XCTAssertNil(MountShadowRules.numericSuffix(of: "Backup", at: "/Volumes/Backup"))
    XCTAssertNil(MountShadowRules.numericSuffix(of: "Backup", at: "/Volumes/Backup Backup"))
    XCTAssertNil(MountShadowRules.numericSuffix(of: "Backup", at: "/Volumes/Backup 1x"))
    XCTAssertNil(MountShadowRules.numericSuffix(of: "Backup", at: "/Volumes/Backup1"))
    XCTAssertNil(MountShadowRules.numericSuffix(of: "Backup", at: "/Volumes/BackupCopy 1"))
  }

  // MARK: - Decision

  func testShadowedPathWithUUIDMatchAtSuffixOneWarns() {
    let result = shadow(records: [
      record("/Volumes/Backup", isMountPoint: false),
      record("/Volumes/Backup 1", uuid: uuid),
    ])
    XCTAssertEqual(result?.actualMountPath, "/Volumes/Backup 1")
    XCTAssertEqual(result?.suffix, 1)
    XCTAssertEqual(result?.volumeUUID, uuid)
  }

  func testSuffixTenWarnsWithThatPath() {
    let result = shadow(records: [
      record("/Volumes/Backup", isMountPoint: false),
      record("/Volumes/Backup 10", uuid: uuid),
    ])
    XCTAssertEqual(result?.actualMountPath, "/Volumes/Backup 10")
    XCTAssertEqual(result?.suffix, 10)
  }

  func testUUIDMismatchGivesNoWarning() {
    let result = shadow(records: [
      record("/Volumes/Backup", isMountPoint: false),
      record("/Volumes/Backup 1", uuid: otherUUID),
    ])
    XCTAssertNil(result)
  }

  func testGenuinelyMountedExpectedPathGivesNoWarning() {
    let result = shadow(records: [record("/Volumes/Backup", uuid: uuid, isMountPoint: true)])
    XCTAssertNil(result)
  }

  func testSuffixedNameBackupGivesNoWarning() {
    let result = shadow(records: [
      record("/Volumes/Backup", isMountPoint: false),
      record("/Volumes/Backup Backup", uuid: uuid),
    ])
    XCTAssertNil(result)
  }

  func testExpectedPathThatDoesNotExistGivesNoWarning() {
    let result = shadow(records: [record("/Volumes/Backup 1", uuid: uuid)])
    XCTAssertNil(result)
  }

  func testSuffixedPathThatIsNotAMountPointGivesNoWarning() {
    let result = shadow(records: [
      record("/Volumes/Backup", isMountPoint: false),
      record("/Volumes/Backup 1", uuid: uuid, isMountPoint: false),
    ])
    XCTAssertNil(result)
  }

  // MARK: - De-duplication

  func testTrackerAnnouncesEachOccurrenceOnce() {
    var tracker = MountShadowAlertTracker()
    let first = MountShadowRules.Shadow(
      name: "Backup", volumeUUID: uuid, actualMountPath: "/Volumes/Backup 1", suffix: 1)
    let second = MountShadowRules.Shadow(
      name: "Backup", volumeUUID: uuid, actualMountPath: "/Volumes/Backup 2", suffix: 2)

    XCTAssertEqual(tracker.newlyShadowed([first]), [first])
    XCTAssertEqual(tracker.newlyShadowed([first]), [])
    // The same volume at a different suffixed path is a new occurrence.
    XCTAssertEqual(tracker.newlyShadowed([second]), [second])
    // Cleared, then recurring: announced again.
    XCTAssertEqual(tracker.newlyShadowed([]), [])
    XCTAssertEqual(tracker.newlyShadowed([first]), [first])
  }
}
