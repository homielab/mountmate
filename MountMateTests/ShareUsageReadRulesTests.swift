//  Created by homielab.com

import XCTest

@testable import MountMate

final class ShareUsageReadRulesTests: XCTestCase {
  private let shareA = UUID()
  private let shareB = UUID()
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func shouldRead(
    requested: Bool = true, mounted: Set<UUID>? = nil, known: Set<UUID>? = nil,
    secondsSinceLastRead: TimeInterval? = 120
  ) -> Bool {
    ShareUsageReadRules.shouldRead(
      requested: requested, mountedShareIDs: mounted ?? [shareA],
      knownUsageIDs: known ?? [shareA],
      lastReadAt: secondsSinceLastRead.map { now.addingTimeInterval(-$0) }, now: now)
  }

  func testKeepAliveRefreshNeverReads() {
    XCTAssertFalse(shouldRead(requested: false))
    XCTAssertFalse(shouldRead(requested: false, known: [], secondsSinceLastRead: nil))
  }

  func testNothingMountedNeverReads() {
    XCTAssertFalse(shouldRead(mounted: [], known: [], secondsSinceLastRead: nil))
  }

  func testFirstReadHappens() {
    XCTAssertTrue(shouldRead(known: [], secondsSinceLastRead: nil))
  }

  func testRecentReadIsReused() {
    XCTAssertFalse(shouldRead(secondsSinceLastRead: 10))
    XCTAssertFalse(shouldRead(secondsSinceLastRead: 59))
  }

  func testReadOlderThanAMinuteIsRepeated() {
    XCTAssertTrue(shouldRead(secondsSinceLastRead: 60))
    XCTAssertTrue(shouldRead(secondsSinceLastRead: 600))
  }

  func testNewlyMountedShareIsReadRightAway() {
    XCTAssertTrue(shouldRead(mounted: [shareA, shareB], known: [shareA], secondsSinceLastRead: 5))
  }

  func testUnmountedShareWithOldUsageDoesNotForceARead() {
    XCTAssertFalse(shouldRead(mounted: [shareA], known: [shareA, shareB], secondsSinceLastRead: 5))
  }
}
