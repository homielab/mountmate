//  Created by homielab.com

import XCTest

@testable import MountMate

final class LowSpaceRulesTests: XCTestCase {
  private func volume(
    _ id: String, used: Double?, mounted: Bool = true, readOnly: Bool = false,
    category: DriveCategory = .user, error: String? = nil
  ) -> Volume {
    var volume = Volume(
      id: id, deviceIdentifier: "disk9s\(id)", diskUUID: nil, name: "Vol \(id)",
      isMounted: mounted, mountPoint: mounted ? "/Volumes/\(id)" : nil, freeSpace: "12 GB",
      totalSize: "100 GB", usedSpace: "88 GB", usedBytes: nil, fileSystemType: "apfs",
      usagePercentage: used, category: category, isProtected: false, snapshots: [])
    volume.isReadOnly = readOnly
    volume.storageError = error
    return volume
  }

  private func disk(_ volumes: [Volume], type: PhysicalDiskType = .physical) -> PhysicalDisk {
    PhysicalDisk(
      id: "disk9", diskUUID: nil, connectionType: "USB", name: "Disk", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: type, isRAIDSet: false,
      partitions: volumes, containers: [], storageError: nil)
  }

  func testWarnsAtAndAboveTheThresholdOnly() {
    XCTAssertNil(LowSpaceRules.warning(for: volume("1", used: 0.89), on: .physical, threshold: 0.9))
    let atLimit = LowSpaceRules.warning(for: volume("1", used: 0.9), on: .physical, threshold: 0.9)
    XCTAssertEqual(atLimit, LowSpaceRules.Warning(percentUsed: 90, free: "12 GB"))
    XCTAssertEqual(
      LowSpaceRules.warning(for: volume("1", used: 0.94), on: .internalDisk, threshold: 0.9)?
        .percentUsed, 94)
  }

  func testNothingWhenOffOrNotApplicable() {
    let full = volume("1", used: 0.99)
    XCTAssertNil(LowSpaceRules.warning(for: full, on: .physical, threshold: nil))
    XCTAssertNil(LowSpaceRules.warning(for: full, on: .diskImage, threshold: 0.9))
    XCTAssertNil(
      LowSpaceRules.warning(
        for: volume("1", used: 0.99, mounted: false), on: .physical, threshold: 0.9))
    XCTAssertNil(
      LowSpaceRules.warning(
        for: volume("1", used: 0.99, readOnly: true), on: .physical, threshold: 0.9))
    XCTAssertNil(
      LowSpaceRules.warning(
        for: volume("1", used: 0.99, category: .system), on: .physical, threshold: 0.9))
    XCTAssertNil(
      LowSpaceRules.warning(for: volume("1", used: 0.99, error: "x"), on: .physical, threshold: 0.9)
    )
    XCTAssertNil(LowSpaceRules.warning(for: volume("1", used: nil), on: .physical, threshold: 0.9))
  }

  func testThresholdReadsTheSettings() {
    let suite = "LowSpaceRulesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(LowSpaceRules.threshold(defaults: defaults), 0.9)
    defaults.set(95, forKey: LowSpaceRules.thresholdKey)
    XCTAssertEqual(LowSpaceRules.threshold(defaults: defaults), 0.95)
    defaults.set(42, forKey: LowSpaceRules.thresholdKey)
    XCTAssertEqual(LowSpaceRules.threshold(defaults: defaults), 0.9)
    defaults.set(false, forKey: LowSpaceRules.enabledKey)
    XCTAssertNil(LowSpaceRules.threshold(defaults: defaults))
    defaults.set(true, forKey: LowSpaceRules.enabledKey)
    XCTAssertEqual(LowSpaceRules.threshold(defaults: defaults), 0.9)
  }

  func testMessageMentionsPercentAndFreeSpace() {
    let message = LowSpaceRules.message(for: .init(percentUsed: 94, free: "12 GB"))
    XCTAssertTrue(message.contains("94"))
    XCTAssertTrue(message.contains("12 GB"))
    XCTAssertTrue(LowSpaceRules.message(for: .init(percentUsed: 94, free: nil)).contains("94"))
  }

  func testTrackerAnnouncesOncePerMountAndAgainAfterRemount() {
    var tracker = LowSpaceAlertTracker()
    let full = [disk([volume("1", used: 0.95), volume("2", used: 0.2)])]
    XCTAssertEqual(tracker.newWarnings(in: full, threshold: 0.9).map(\.volume.id), ["1"])
    XCTAssertTrue(tracker.newWarnings(in: full, threshold: 0.9).isEmpty)
    // Unmounted, then mounted again: announced again.
    let unmounted = [disk([volume("1", used: 0.95, mounted: false)])]
    XCTAssertTrue(tracker.newWarnings(in: unmounted, threshold: 0.9).isEmpty)
    XCTAssertEqual(tracker.newWarnings(in: full, threshold: 0.9).map(\.volume.id), ["1"])
  }

  func testTrackerStaysQuietWhileTheWarningIsOff() {
    var tracker = LowSpaceAlertTracker()
    let full = [disk([volume("1", used: 0.95)])]
    XCTAssertTrue(tracker.newWarnings(in: full, threshold: nil).isEmpty)
    XCTAssertEqual(tracker.newWarnings(in: full, threshold: 0.9).count, 1)
  }

  func testWarningsListsEveryFullVolume() {
    let disks = [
      disk([volume("1", used: 0.95)]), disk([volume("2", used: 0.99)], type: .diskImage),
    ]
    XCTAssertEqual(LowSpaceRules.warnings(in: disks, threshold: 0.9).count, 1)
  }
}
