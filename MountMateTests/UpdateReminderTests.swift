import XCTest

@testable import MountMate

final class UpdateReminderTests: XCTestCase {
  func testSparkleNeverShowsScheduledUpdatesItself() {
    XCTAssertFalse(UpdateReminder.standardDriverShowsScheduledUpdate(immediateFocus: true))
    XCTAssertFalse(UpdateReminder.standardDriverShowsScheduledUpdate(immediateFocus: false))
  }

  func testScheduledUpdateBecomesReminder() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledByStandardDriver: false, userInitiated: false, version: "6.4")
    XCTAssertEqual(reminder.pendingVersion, "6.4")
    XCTAssertTrue(reminder.hasPendingUpdate)
  }

  func testUserInitiatedCheckShowsWindowWithoutReminder() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledByStandardDriver: true, userInitiated: true, version: "6.4")
    XCTAssertNil(reminder.pendingVersion)
  }

  func testUpdateShownBySparkleLeavesNoReminder() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledByStandardDriver: true, userInitiated: false, version: "6.4")
    XCTAssertFalse(reminder.hasPendingUpdate)
  }

  func testUserInitiatedCheckClearsEarlierReminder() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledByStandardDriver: false, userInitiated: false, version: "6.4")
    reminder.willShowUpdate(handledByStandardDriver: true, userInitiated: true, version: "6.5")
    XCTAssertNil(reminder.pendingVersion)
  }

  func testNewerScheduledUpdateReplacesVersion() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledByStandardDriver: false, userInitiated: false, version: "6.4")
    reminder.willShowUpdate(handledByStandardDriver: false, userInitiated: false, version: "6.5")
    XCTAssertEqual(reminder.pendingVersion, "6.5")
  }

  func testAttentionClearsReminder() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledByStandardDriver: false, userInitiated: false, version: "6.4")
    reminder.userGaveAttention()
    XCTAssertFalse(reminder.hasPendingUpdate)
  }

  func testSessionEndClearsReminder() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledByStandardDriver: false, userInitiated: false, version: "6.4")
    reminder.updateSessionFinished()
    XCTAssertFalse(reminder.hasPendingUpdate)
  }
}
