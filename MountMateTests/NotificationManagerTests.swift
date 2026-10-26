//  Created by homielab.com

import UserNotifications
import XCTest

@testable import MountMate

private final class FakeNotificationCenter: NotificationCentering {
  var status: UNAuthorizationStatus = .notDetermined
  var grantsPermission = true
  private(set) var authorizationRequests = 0
  private(set) var added: [UNNotificationRequest] = []
  private(set) var delegateSet = false

  func setDelegate(_ delegate: UNUserNotificationCenterDelegate) { delegateSet = true }

  func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
    authorizationRequests += 1
    completion(grantsPermission, nil)
  }

  func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
    completion(status)
  }

  func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
    added.append(request)
    completion(nil)
  }
}

final class NotificationManagerTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!
  private var center: FakeNotificationCenter!

  override func setUp() {
    suiteName = "NotificationManagerTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    center = FakeNotificationCenter()
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
  }

  private func makeManager() -> NotificationManager {
    NotificationManager(center: center, defaults: defaults)
  }

  /// Lets the manager's main-thread hops run.
  private func drainMainQueue() {
    let done = expectation(description: "main queue")
    DispatchQueue.main.async { done.fulfill() }
    wait(for: [done], timeout: 2)
  }

  func testIsOffByDefaultAndReadsTheSavedSetting() {
    XCTAssertFalse(makeManager().isEnabled)
    defaults.set(true, forKey: NotificationManager.enabledKey)
    XCTAssertTrue(makeManager().isEnabled)
  }

  func testTurningOnSavesTheSettingAndAsksForPermissionOnce() {
    let manager = makeManager()
    manager.isEnabled = true
    drainMainQueue()
    XCTAssertTrue(defaults.bool(forKey: NotificationManager.enabledKey))
    XCTAssertEqual(center.authorizationRequests, 1)
    XCTAssertTrue(manager.canDeliver)
    XCTAssertFalse(manager.isDeniedBySystem)
    manager.isEnabled = true
    XCTAssertEqual(center.authorizationRequests, 1)
  }

  func testDecliningThePromptMarksTheSettingAsDeniedBySystem() {
    center.grantsPermission = false
    let manager = makeManager()
    manager.isEnabled = true
    drainMainQueue()
    XCTAssertTrue(manager.isDeniedBySystem)
    XCTAssertFalse(manager.canDeliver)
  }

  func testTurningOffSavesTheSettingWithoutAskingAgain() {
    let manager = makeManager()
    manager.isEnabled = true
    drainMainQueue()
    manager.isEnabled = false
    XCTAssertFalse(defaults.bool(forKey: NotificationManager.enabledKey))
    XCTAssertEqual(center.authorizationRequests, 1)
  }

  func testStartReadsADeniedPermission() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    center.status = .denied
    let manager = makeManager()
    manager.start()
    drainMainQueue()
    XCTAssertTrue(center.delegateSet)
    XCTAssertTrue(manager.isDeniedBySystem)
    XCTAssertFalse(manager.canDeliver)
  }

  func testStartReadsAGrantedPermission() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    center.status = .authorized
    let manager = makeManager()
    manager.start()
    drainMainQueue()
    XCTAssertFalse(manager.isDeniedBySystem)
    XCTAssertTrue(manager.canDeliver)
  }

  func testStartAsksAgainWhenThePromptWasNeverAnswered() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    center.status = .notDetermined
    let manager = makeManager()
    manager.start()
    drainMainQueue()
    XCTAssertEqual(center.authorizationRequests, 1)
    XCTAssertTrue(manager.canDeliver)
  }

  func testStartDoesNothingWhileTheSettingIsOff() {
    center.status = .denied
    let manager = makeManager()
    manager.start()
    drainMainQueue()
    XCTAssertFalse(manager.isDeniedBySystem)
    XCTAssertEqual(center.authorizationRequests, 0)
  }

  func testNothingIsPostedWhileTheSettingIsOff() {
    let manager = makeManager()
    manager.sleepUnmountTimedOut()
    XCTAssertTrue(center.added.isEmpty)
  }

  func testEventsArePostedWhenOnAndIdleUnmountReportsDelivery() {
    let manager = makeManager()
    XCTAssertFalse(manager.idleUnmounted(message: "m", volumeID: "v"))
    manager.isEnabled = true
    drainMainQueue()
    manager.sleepUnmountTimedOut()
    XCTAssertEqual(center.added.map(\.identifier), ["sleepUnmount"])
    XCTAssertTrue(manager.idleUnmounted(message: "m", volumeID: "v"))
    XCTAssertEqual(center.added.last?.identifier, "idle.v")
  }
}
