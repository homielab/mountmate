//  Created by homielab.com

import XCTest

@testable import MountMate

final class KeepAliveManagerTests: XCTestCase {
  func testBackoffDelayDoublesAndCaps() {
    let manager = KeepAliveManager.shared

    let original = manager.retryInterval
    defer { manager.retryInterval = original }

    manager.retryInterval = 30

    XCTAssertEqual(manager.backoffDelay(forAttempt: 0), 30)
    XCTAssertEqual(manager.backoffDelay(forAttempt: 1), 30)
    XCTAssertEqual(manager.backoffDelay(forAttempt: 2), 60)
    XCTAssertEqual(manager.backoffDelay(forAttempt: 3), 120)
    XCTAssertEqual(manager.backoffDelay(forAttempt: 4), 240)
    // Cap is 8x the base interval.
    XCTAssertEqual(manager.backoffDelay(forAttempt: 5), 240)
    XCTAssertEqual(manager.backoffDelay(forAttempt: 20), 240)
  }

  func testBackoffDelayScalesWithBaseInterval() {
    let manager = KeepAliveManager.shared

    let original = manager.retryInterval
    defer { manager.retryInterval = original }

    manager.retryInterval = 10
    XCTAssertEqual(manager.backoffDelay(forAttempt: 1), 10)
    XCTAssertEqual(manager.backoffDelay(forAttempt: 3), 40)

    manager.retryInterval = 300
    XCTAssertEqual(manager.backoffDelay(forAttempt: 1), 300)
    XCTAssertEqual(manager.backoffDelay(forAttempt: 10), 2400)
  }
}
