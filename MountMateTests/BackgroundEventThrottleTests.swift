//  Created by homielab.com

import XCTest

@testable import MountMate

final class BackgroundEventThrottleTests: XCTestCase {
  func testFirstFailureStaysQuietSecondIsAnnouncedOnce() {
    var throttle = BackgroundEventThrottle()
    XCTAssertFalse(throttle.recordFailure("share.a"))
    XCTAssertTrue(throttle.recordFailure("share.a"))
    // Further retries in the same outage never notify again.
    for _ in 0..<20 {
      XCTAssertFalse(throttle.recordFailure("share.a"))
    }
    XCTAssertTrue(throttle.hasAnnouncedFailure("share.a"))
  }

  func testRecoveryIsAnnouncedOnlyAfterAnAnnouncedFailure() {
    var throttle = BackgroundEventThrottle()
    // Healthy targets report success on every sweep: nothing to announce.
    XCTAssertFalse(throttle.recordSuccess("share.a"))
    XCTAssertFalse(throttle.recordSuccess("share.a"))

    // One failed attempt after wake, then back: stays quiet both ways.
    XCTAssertFalse(throttle.recordFailure("share.a"))
    XCTAssertFalse(throttle.recordSuccess("share.a"))

    _ = throttle.recordFailure("share.a")
    _ = throttle.recordFailure("share.a")
    XCTAssertTrue(throttle.recordSuccess("share.a"))
    XCTAssertFalse(throttle.recordSuccess("share.a"))
  }

  func testSuccessResetsTheFailureCount() {
    var throttle = BackgroundEventThrottle()
    XCTAssertFalse(throttle.recordFailure("v"))
    XCTAssertFalse(throttle.recordSuccess("v"))
    // A new outage starts counting from zero.
    XCTAssertFalse(throttle.recordFailure("v"))
    XCTAssertTrue(throttle.recordFailure("v"))
  }

  func testNewOutageAfterRecoveryIsAnnouncedAgain() {
    var throttle = BackgroundEventThrottle(failuresBeforeNotice: 1)
    XCTAssertTrue(throttle.recordFailure("v"))
    XCTAssertTrue(throttle.recordSuccess("v"))
    XCTAssertTrue(throttle.recordFailure("v"))
  }

  func testTargetsAreIndependent() {
    var throttle = BackgroundEventThrottle(failuresBeforeNotice: 1)
    XCTAssertTrue(throttle.recordFailure("share.a"))
    XCTAssertTrue(throttle.recordFailure("volume.b"))
    XCTAssertTrue(throttle.recordSuccess("volume.b"))
    XCTAssertTrue(throttle.hasAnnouncedFailure("share.a"))
  }

  func testForgetAndResetDropHistoryWithoutRecovery() {
    var throttle = BackgroundEventThrottle(failuresBeforeNotice: 1)
    XCTAssertTrue(throttle.recordFailure("a"))
    throttle.forget("a")
    // The user unmounted it: mounting again is not a "reconnected" event.
    XCTAssertFalse(throttle.recordSuccess("a"))

    XCTAssertTrue(throttle.recordFailure("b"))
    throttle.reset()
    XCTAssertFalse(throttle.recordSuccess("b"))
    XCTAssertTrue(throttle.recordFailure("b"))
  }

  func testThresholdIsAtLeastOne() {
    var throttle = BackgroundEventThrottle(failuresBeforeNotice: 0)
    XCTAssertEqual(throttle.failuresBeforeNotice, 1)
    XCTAssertTrue(throttle.recordFailure("a"))
  }

  func testNotificationKeysSeparateSharesAndVolumes() {
    let id = UUID()
    XCTAssertEqual(KeepAliveManager.notificationKey(shareID: id), "share.\(id.uuidString)")
    XCTAssertEqual(KeepAliveManager.notificationKey(volumeID: "disk4s1"), "volume.disk4s1")
  }
}
