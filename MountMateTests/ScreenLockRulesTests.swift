//  Created by homielab.com

import XCTest

@testable import MountMate

final class ScreenLockRulesTests: XCTestCase {
  private func volume(_ name: String) -> Volume {
    Volume(
      id: name, deviceIdentifier: "disk9s1", diskUUID: nil, name: name, isMounted: true,
      mountPoint: "/Volumes/\(name)", freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: "apfs", usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  func testOffDoesNothing() {
    XCTAssertEqual(
      ScreenLockRules.decision(isEnabled: false, candidateCount: 3, isSleepUnmountRunning: false),
      .off)
    XCTAssertEqual(
      ScreenLockRules.decision(isEnabled: false, candidateCount: 0, isSleepUnmountRunning: true),
      .off)
  }

  func testOnWithoutCandidatesSkips() {
    XCTAssertEqual(
      ScreenLockRules.decision(isEnabled: true, candidateCount: 0, isSleepUnmountRunning: false),
      .nothingToUnmount)
  }

  func testRunningSleepUnmountIsNotOverlapped() {
    XCTAssertEqual(
      ScreenLockRules.decision(isEnabled: true, candidateCount: 2, isSleepUnmountRunning: true),
      .sleepUnmountRunning)
  }

  func testOnWithCandidatesUnmounts() {
    XCTAssertEqual(
      ScreenLockRules.decision(isEnabled: true, candidateCount: 1, isSleepUnmountRunning: false),
      .unmount)
  }

  func testCandidatesLeaveKeepAliveVolumesMounted() {
    let volumes = [volume("A"), volume("Kept"), volume("B")]
    let candidates = ScreenLockRules.candidates(
      fromAutomatic: volumes, isKeepAlive: { $0.name == "Kept" })
    XCTAssertEqual(candidates.map(\.name), ["A", "B"])
  }

  func testWaitsForUnlockOnlyWhileLockedWithSettingOn() {
    XCTAssertTrue(ScreenLockRules.waitsForUnlock(isEnabled: true, isScreenLocked: true))
    XCTAssertFalse(ScreenLockRules.waitsForUnlock(isEnabled: true, isScreenLocked: false))
    XCTAssertFalse(ScreenLockRules.waitsForUnlock(isEnabled: false, isScreenLocked: true))
  }

  func testSettingIsOffByDefault() throws {
    let suite = "ScreenLockRulesTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertFalse(ScreenLockRules.isEnabled(defaults: defaults))
    defaults.set(true, forKey: ScreenLockRules.enabledKey)
    XCTAssertTrue(ScreenLockRules.isEnabled(defaults: defaults))
  }
}
