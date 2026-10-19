//  Created by homielab.com

import Network
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

  func testAutomaticMountKeepsBackoffAndSuppression() {
    let manager = KeepAliveManager.shared
    let share = NetworkShare(
      name: "KeepAliveTest-\(UUID().uuidString)", server: "invalid.example", sharePath: "x",
      username: "")

    // A user eject suppresses the share; keep-alive attempts accumulate.
    manager.suppress(shareID: share.id)
    defer { manager.resume(shareID: share.id) }
    manager.recordAttempt(shareID: share.id)
    manager.recordAttempt(shareID: share.id)
    XCTAssertEqual(manager.retryAttempt(forShareID: share.id), 2)

    // An automatic (keep-alive) mount must neither reset the backoff nor
    // undo the suppression. For a suppressed share it returns immediately
    // without touching the network.
    let done = expectation(description: "mount completion")
    NetworkMountManager.shared.mount(share: share, userInitiated: false) { success, _ in
      XCTAssertFalse(success)
      done.fulfill()
    }
    wait(for: [done], timeout: 5)

    XCTAssertEqual(manager.retryAttempt(forShareID: share.id), 2)
    XCTAssertTrue(manager.isSuppressed(shareID: share.id))
  }

  func testResumeClearsBackoffAndSuppression() {
    let manager = KeepAliveManager.shared
    let id = UUID()
    manager.suppress(shareID: id)
    manager.recordAttempt(shareID: id)

    manager.resume(shareID: id)

    XCTAssertEqual(manager.retryAttempt(forShareID: id), 0)
    XCTAssertFalse(manager.isSuppressed(shareID: id))
  }

  func testUnsuppressKeepsRetryState() {
    let manager = KeepAliveManager.shared
    let id = UUID()
    defer { manager.resume(shareID: id) }
    manager.suppress(shareID: id)
    manager.recordAttempt(shareID: id)

    manager.unsuppress(shareID: id)

    XCTAssertFalse(manager.isSuppressed(shareID: id))
    XCTAssertEqual(manager.retryAttempt(forShareID: id), 1)
  }

  func testWakeOrRecoverySweepClearsBackoffDelayButKeepsAttempts() {
    let manager = KeepAliveManager.shared
    let id = UUID()
    defer { manager.resume(shareID: id) }
    manager.recordAttempt(shareID: id)
    manager.recordAttempt(shareID: id)
    XCTAssertNotNil(manager.nextRetryDate(forShareID: id))

    manager.sweepNow(resetBackoff: true)
    let done = expectation(description: "sweep scheduled")
    DispatchQueue.main.async { done.fulfill() }
    wait(for: [done], timeout: 5)

    XCTAssertNil(manager.nextRetryDate(forShareID: id))
    XCTAssertEqual(manager.retryAttempt(forShareID: id), 2)
  }

  func testInterfaceChangeDetectionIgnoresTunnels() {
    typealias Snapshot = KeepAliveManager.InterfaceSnapshot
    let wifi = Snapshot(name: "en0", type: .wifi)
    let ethernet = Snapshot(name: "en5", type: .wiredEthernet)

    // First observation / recovery from offline: sweep, don't remount.
    XCTAssertFalse(
      KeepAliveManager.shouldRemountShares(previous: nil, current: wifi, available: [wifi]))
    // Same physical interface (VPN tunnels come and go, but are filtered
    // out before this point): no remount.
    XCTAssertFalse(
      KeepAliveManager.shouldRemountShares(previous: wifi, current: wifi, available: [wifi]))
    // Ethernet plugged in while Wi-Fi stays up: primary kind changed.
    XCTAssertTrue(
      KeepAliveManager.shouldRemountShares(
        previous: wifi, current: ethernet, available: [ethernet, wifi]))
    // The interface the shares used disappeared.
    XCTAssertTrue(
      KeepAliveManager.shouldRemountShares(
        previous: ethernet, current: wifi, available: [wifi]))
    // Another Wi-Fi interface became primary while the old one is gone.
    let wifi2 = Snapshot(name: "en1", type: .wifi)
    XCTAssertTrue(
      KeepAliveManager.shouldRemountShares(previous: wifi, current: wifi2, available: [wifi2]))
  }
}
