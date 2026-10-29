//  Created by homielab.com

import XCTest

@testable import MountMate

final class ShareUsageReadRulesTests: XCTestCase {
  private let shareA = UUID()
  private let shareB = UUID()
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func shouldRead(
    requested: Bool = true, mounted: Set<UUID>? = nil, attempted: Set<UUID>? = nil,
    secondsSinceLastRead: TimeInterval? = 120
  ) -> Bool {
    ShareUsageReadRules.shouldRead(
      requested: requested, mountedShareIDs: mounted ?? [shareA],
      attemptedShareIDs: attempted ?? [shareA],
      lastReadAt: secondsSinceLastRead.map { now.addingTimeInterval(-$0) }, now: now)
  }

  func testKeepAliveRefreshNeverReads() {
    XCTAssertFalse(shouldRead(requested: false))
    XCTAssertFalse(shouldRead(requested: false, attempted: [], secondsSinceLastRead: nil))
  }

  func testNothingMountedNeverReads() {
    XCTAssertFalse(shouldRead(mounted: [], attempted: [], secondsSinceLastRead: nil))
  }

  func testFirstReadHappens() {
    XCTAssertTrue(shouldRead(attempted: [], secondsSinceLastRead: nil))
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
    XCTAssertTrue(
      shouldRead(mounted: [shareA, shareB], attempted: [shareA], secondsSinceLastRead: 5))
  }

  func testUnmountedShareFromLastReadDoesNotForceARead() {
    XCTAssertFalse(
      shouldRead(mounted: [shareA], attempted: [shareA, shareB], secondsSinceLastRead: 5))
  }

  // A share whose last read timed out or failed has no capacity, but it was
  // asked: it waits for the minute like the others instead of making every
  // refresh read all shares again.
  func testShareThatDidNotAnswerWaitsForTheInterval() {
    let attempted: Set<UUID> = [shareA, shareB]
    XCTAssertFalse(shouldRead(mounted: attempted, attempted: attempted, secondsSinceLastRead: 5))
    XCTAssertTrue(shouldRead(mounted: attempted, attempted: attempted, secondsSinceLastRead: 60))
  }

  // Unmounting drops a share from the last read, so mounting it again
  // within the minute reads it right away.
  func testRemountedShareIsReadRightAway() {
    XCTAssertTrue(shouldRead(mounted: [shareB], attempted: [], secondsSinceLastRead: 5))
  }
}
