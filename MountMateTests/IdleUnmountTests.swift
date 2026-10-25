//  Created by homielab.com

import XCTest

@testable import MountMate

final class IdleUnmountTests: XCTestCase {
  private typealias Tracker = IdleUnmountTracker
  private typealias Activity = IdleUnmountTracker.Activity

  private let start = Date(timeIntervalSince1970: 10_000)
  private let maxGap: TimeInterval = 90

  private func candidate(_ id: String = "vol", disk: String = "disk4", minutes: Int = 1)
    -> Tracker.Candidate
  {
    .init(volumeID: id, diskID: disk, limit: TimeInterval(minutes) * 60)
  }

  // MARK: - Tracker

  func testUnmountsAfterLimitWithoutActivity() {
    var tracker = Tracker()
    let quiet = ["disk4": Activity(reads: 10, writes: 5)]
    XCTAssertEqual(
      tracker.evaluate([candidate()], activity: quiet, now: start, maxGap: maxGap), [])
    XCTAssertEqual(
      tracker.evaluate(
        [candidate()], activity: quiet, now: start + 30, maxGap: maxGap), [])
    XCTAssertEqual(
      tracker.evaluate(
        [candidate()], activity: quiet, now: start + 60, maxGap: maxGap), ["vol"])
  }

  func testActivityRestartsTheIdlePeriod() {
    var tracker = Tracker()
    _ = tracker.evaluate(
      [candidate()], activity: ["disk4": Activity(reads: 10, writes: 5)], now: start,
      maxGap: maxGap)
    // A copy in progress: counters keep moving.
    XCTAssertEqual(
      tracker.evaluate(
        [candidate()], activity: ["disk4": Activity(reads: 10, writes: 900)], now: start + 45,
        maxGap: maxGap), [])
    XCTAssertEqual(
      tracker.evaluate(
        [candidate()], activity: ["disk4": Activity(reads: 10, writes: 900)], now: start + 90,
        maxGap: maxGap), [])
    XCTAssertEqual(
      tracker.evaluate(
        [candidate()], activity: ["disk4": Activity(reads: 10, writes: 900)], now: start + 105,
        maxGap: maxGap), ["vol"])
  }

  func testUnreadableCountersNeverUnmount() {
    var tracker = Tracker()
    for step in 0..<10 {
      XCTAssertEqual(
        tracker.evaluate(
          [candidate()], activity: [:], now: start + TimeInterval(step * 60), maxGap: maxGap),
        [])
    }
  }

  func testAfterAnAttemptWaitsAnotherFullPeriod() {
    var tracker = Tracker()
    let quiet = ["disk4": Activity(reads: 1, writes: 1)]
    _ = tracker.evaluate([candidate()], activity: quiet, now: start, maxGap: maxGap)
    XCTAssertEqual(
      tracker.evaluate([candidate()], activity: quiet, now: start + 60, maxGap: maxGap), ["vol"])
    // The unmount failed (files open); not retried on the next check.
    XCTAssertEqual(
      tracker.evaluate([candidate()], activity: quiet, now: start + 90, maxGap: maxGap), [])
    XCTAssertEqual(
      tracker.evaluate([candidate()], activity: quiet, now: start + 120, maxGap: maxGap), ["vol"])
  }

  func testLongGapSinceLastCheckCountsAsActivity() {
    var tracker = Tracker()
    let quiet = ["disk4": Activity(reads: 1, writes: 1)]
    _ = tracker.evaluate([candidate()], activity: quiet, now: start, maxGap: maxGap)
    // The Mac slept for an hour: no unmount right after wake.
    XCTAssertEqual(
      tracker.evaluate([candidate()], activity: quiet, now: start + 3600, maxGap: maxGap), [])
    XCTAssertEqual(
      tracker.evaluate([candidate()], activity: quiet, now: start + 3660, maxGap: maxGap), ["vol"])
  }

  func testVolumeThatLeftStartsFreshWhenBack() {
    var tracker = Tracker()
    let quiet = ["disk4": Activity(reads: 1, writes: 1)]
    _ = tracker.evaluate([candidate()], activity: quiet, now: start, maxGap: maxGap)
    _ = tracker.evaluate([], activity: [:], now: start + 30, maxGap: maxGap)
    XCTAssertEqual(
      tracker.evaluate([candidate()], activity: quiet, now: start + 60, maxGap: maxGap), [])
    XCTAssertEqual(
      tracker.evaluate([candidate()], activity: quiet, now: start + 120, maxGap: maxGap), ["vol"])
  }

  func testEachVolumeKeepsItsOwnLimit() {
    var tracker = Tracker()
    let quiet = ["disk4": Activity(reads: 1, writes: 1), "disk5": Activity(reads: 7, writes: 7)]
    let candidates = [candidate("a", minutes: 1), candidate("b", disk: "disk5", minutes: 2)]
    _ = tracker.evaluate(candidates, activity: quiet, now: start, maxGap: maxGap)
    XCTAssertEqual(
      tracker.evaluate(candidates, activity: quiet, now: start + 60, maxGap: maxGap), ["a"])
    XCTAssertEqual(
      tracker.evaluate(candidates, activity: quiet, now: start + 120, maxGap: maxGap),
      ["a", "b"])
  }

  func testCheckIntervalIsHalfTheLimitWithinBounds() {
    XCTAssertEqual(Tracker.checkInterval(forMinutes: 1), 30)
    XCTAssertEqual(Tracker.checkInterval(forMinutes: 5), 150)
    XCTAssertEqual(Tracker.checkInterval(forMinutes: 15), 300)
    XCTAssertEqual(Tracker.checkInterval(forMinutes: 60), 300)
  }

  // MARK: - Candidates

  private let volumeUUID = "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"
  private let diskUUID = "0A1B2C3D-0000-1111-2222-333344445555"

  private func volume(
    mounted: Bool = true, mountPoint: String? = "/Volumes/Backup", category: DriveCategory = .user
  ) -> Volume {
    Volume(
      id: volumeUUID, deviceIdentifier: "disk4s2", diskUUID: diskUUID, name: "Backup",
      isMounted: mounted, mountPoint: mounted ? mountPoint : nil, freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: nil, fileSystemType: "apfs", usagePercentage: nil,
      category: category, isProtected: false, snapshots: [], storageError: nil)
  }

  private func disk(_ type: PhysicalDiskType, volumes: [Volume]) -> PhysicalDisk {
    PhysicalDisk(
      id: "disk4", diskUUID: nil, connectionType: "USB", name: "Drive", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: type, isRAIDSet: false,
      partitions: volumes, containers: [])
  }

  private var setting: IdleUnmountVolume {
    IdleUnmountVolume(volumeUUID: volumeUUID, diskUUID: diskUUID, name: "Backup", minutes: 15)
  }

  private func candidates(
    _ disks: [PhysicalDisk], settings: [IdleUnmountVolume]? = nil,
    keepAlive: Set<String> = [], busy: Set<String> = [], unverified: Set<String> = []
  ) -> [Tracker.Candidate] {
    IdleUnmountManager.candidates(
      disks: disks, unverifiedDiskIDs: unverified, settings: settings ?? [setting],
      keepAliveIDs: keepAlive, busyVolumeIDs: busy)
  }

  func testMountedExternalVolumeWithSettingIsCandidate() {
    XCTAssertEqual(
      candidates([disk(.physical, volumes: [volume()])]),
      [.init(volumeID: volumeUUID, diskID: "disk4", limit: 900)])
  }

  func testIneligibleVolumesAreSkipped() {
    let compositeId = setting.id
    XCTAssertEqual(candidates([disk(.internalDisk, volumes: [volume()])]), [])
    XCTAssertEqual(candidates([disk(.diskImage, volumes: [volume()])]), [])
    XCTAssertEqual(candidates([disk(.physical, volumes: [volume(mounted: false)])]), [])
    XCTAssertEqual(candidates([disk(.physical, volumes: [volume(category: .system)])]), [])
    XCTAssertEqual(candidates([disk(.physical, volumes: [volume(mountPoint: "/")])]), [])
    XCTAssertEqual(
      candidates([disk(.physical, volumes: [volume()])], keepAlive: [compositeId]), [])
    XCTAssertEqual(candidates([disk(.physical, volumes: [volume()])], busy: [volumeUUID]), [])
    XCTAssertEqual(
      candidates([disk(.physical, volumes: [volume()])], unverified: ["disk4"]), [])
    var off = setting
    off.minutes = 0
    XCTAssertEqual(candidates([disk(.physical, volumes: [volume()])], settings: [off]), [])
    XCTAssertEqual(candidates([disk(.physical, volumes: [volume()])], settings: []), [])
  }

  // MARK: - Statistics and settings

  func testActivityFromBlockStorageStatistics() {
    let statistics: [String: Any] = [
      "Operations (Read)": NSNumber(value: 4449), "Operations (Write)": NSNumber(value: 1964),
      "Bytes (Read)": NSNumber(value: 18_669_568),
    ]
    XCTAssertEqual(
      IdleUnmountManager.activity(fromStatistics: statistics), Activity(reads: 4449, writes: 1964))
    XCTAssertNil(IdleUnmountManager.activity(fromStatistics: ["Bytes (Read)": NSNumber(value: 1)]))
  }

  func testSettingDecodesWithoutMinutesAsOff() throws {
    let json = Data(
      #"[{"volumeUUID":"V","diskUUID":"D","name":"Backup"},{"volumeUUID":"W","diskUUID":"D","name":"Media","minutes":30}]"#
        .utf8)
    let decoded = try JSONDecoder().decode([IdleUnmountVolume].self, from: json)
    XCTAssertEqual(decoded.map(\.minutes), [0, 30])
    XCTAssertEqual(decoded[1].id, "D-W")
  }

  func testSettingRoundTrips() throws {
    let data = try JSONEncoder().encode([setting])
    XCTAssertEqual(try JSONDecoder().decode([IdleUnmountVolume].self, from: data), [setting])
  }
}
