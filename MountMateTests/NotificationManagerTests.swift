//  Created by homielab.com

import AppKit
import UserNotifications
import XCTest

@testable import MountMate

private final class FakeNotificationCenter: NotificationCentering {
  var status: UNAuthorizationStatus = .notDetermined
  var grantsPermission = true
  private(set) var authorizationRequests = 0
  private(set) var added: [UNNotificationRequest] = []
  private(set) var delegateSet = false
  private(set) var categories: Set<UNNotificationCategory> = []

  func setDelegate(_ delegate: UNUserNotificationCenterDelegate) { delegateSet = true }

  func setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }

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
  /// Stands in for `NotificationCenter.default`, so the test host app
  /// becoming active cannot trigger an extra permission check.
  private var activation: NotificationCenter!
  /// Stands in for `NSWorkspace.shared.notificationCenter`.
  private var workspace: NotificationCenter!
  /// The kernel mount table the manager sees.
  private var mountedPaths: Set<String>? = []
  private var clock = Date(timeIntervalSince1970: 1_000_000)

  override func setUp() {
    suiteName = "NotificationManagerTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    center = FakeNotificationCenter()
    activation = NotificationCenter()
    workspace = NotificationCenter()
    mountedPaths = []
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
  }

  /// The manager runs its main-thread hops right away, so every permission
  /// check (even one that asks again and hops twice) has finished when the
  /// call returns.
  private func makeManager() -> NotificationManager {
    NotificationManager(
      center: center, defaults: defaults, activationNotifications: activation,
      workspaceNotifications: workspace, performOnMain: { $0() },
      mountedPaths: { [unowned self] in self.mountedPaths }, now: { [unowned self] in self.clock })
  }

  private func cardWithBackup() -> PhysicalDisk {
    var card = disk("disk4", smart: .verified)
    card.partitions = [
      Volume(
        id: "v1", deviceIdentifier: "disk4s1", diskUUID: nil, name: "Backup", isMounted: true,
        mountPoint: "/Volumes/Backup", freeSpace: nil, totalSize: nil, usedSpace: nil,
        usedBytes: nil, fileSystemType: "ExFAT", usagePercentage: nil, category: .user,
        isProtected: false, snapshots: [])
    ]
    return card
  }

  func testPulledOutVolumeIsAnnouncedWhenTheWarningIsOn() {
    let manager = makeManager()
    manager.start()
    manager.isEnabled = true
    // Off by default: nothing is watched.
    manager.disksRefreshed([cardWithBackup()])
    manager.disksRefreshed([])
    XCTAssertEqual(center.added.count, 0)

    defaults.set(true, forKey: UnexpectedRemovalTracker.enabledKey)
    manager.disksRefreshed([cardWithBackup()])
    manager.disksRefreshed([])
    XCTAssertEqual(center.added.map(\.identifier), ["removed.v1"])
    XCTAssertEqual(
      center.added.first?.content.body,
      "“Backup” was disconnected without being ejected. Check your files.")
  }

  func testRequestedUnmountOrEjectIsNotAnnounced() {
    let manager = makeManager()
    manager.start()
    manager.isEnabled = true
    defaults.set(true, forKey: UnexpectedRemovalTracker.enabledKey)

    manager.disksRefreshed([cardWithBackup()])
    workspace.post(
      name: NSWorkspace.willUnmountNotification, object: nil,
      userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(fileURLWithPath: "/Volumes/Backup")])
    manager.disksRefreshed([])

    manager.disksRefreshed([cardWithBackup()])
    manager.disksRefreshed([], ejectingDiskIDs: ["disk4"])
    XCTAssertEqual(center.added.count, 0)
  }

  func testNothingIsAnnouncedAcrossSleepAndRightAfterWake() {
    let manager = makeManager()
    manager.start()
    manager.isEnabled = true
    defaults.set(true, forKey: UnexpectedRemovalTracker.enabledKey)

    manager.disksRefreshed([cardWithBackup()])
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    manager.disksRefreshed([])
    XCTAssertEqual(center.added.count, 0)
  }

  private func disk(_ id: String, smart: SMARTStatus) -> PhysicalDisk {
    PhysicalDisk(
      id: id, diskUUID: nil, connectionType: "USB", name: "Disk \(id)", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: .physical, isRAIDSet: false,
      partitions: [], containers: [], storageError: nil, smartStatus: smart)
  }

  func testFailingDiskIsAnnouncedOnceAcrossRefreshes() {
    let manager = makeManager()
    manager.isEnabled = true
    let disks = [disk("disk6", smart: .failing), disk("disk7", smart: .verified)]
    manager.disksRefreshed(disks)
    manager.disksRefreshed(disks)
    XCTAssertEqual(center.added.map(\.identifier), ["smart.disk6"])
    manager.disksRefreshed(disks + [disk("disk8", smart: .failing)])
    XCTAssertEqual(center.added.map(\.identifier), ["smart.disk6", "smart.disk8"])
  }

  func testNothingIsAnnouncedWhenNotificationsAreOffOrStatusIsNotFailing() {
    let manager = makeManager()
    manager.disksRefreshed([disk("disk6", smart: .failing)])
    XCTAssertTrue(center.added.isEmpty)
    manager.isEnabled = true
    manager.disksRefreshed([
      disk("disk6", smart: .verified), disk("disk7", smart: .notSupported),
      disk("disk8", smart: .unknown),
    ])
    XCTAssertTrue(center.added.isEmpty)
    // Turned on later: a disk that is still failing is announced then.
    manager.disksRefreshed([disk("disk6", smart: .failing)])
    XCTAssertEqual(center.added.count, 1)
  }

  func testAlmostFullVolumeIsAnnouncedOncePerMountWhenTheWarningIsOn() {
    let manager = makeManager()
    manager.isEnabled = true
    func full(mounted: Bool) -> PhysicalDisk {
      let volume = Volume(
        id: "v1", deviceIdentifier: "disk6s1", diskUUID: nil, name: "Backup", isMounted: mounted,
        mountPoint: mounted ? "/Volumes/Backup" : nil, freeSpace: "5 GB", totalSize: "100 GB",
        usedSpace: "95 GB", usedBytes: nil, fileSystemType: "apfs", usagePercentage: 0.95,
        category: .user, isProtected: false, snapshots: [])
      var disk = disk("disk6", smart: .verified)
      disk.partitions = [volume]
      return disk
    }
    manager.disksRefreshed([full(mounted: true)])
    manager.disksRefreshed([full(mounted: true)])
    XCTAssertEqual(center.added.map(\.identifier), ["lowSpace.v1"])
    manager.disksRefreshed([full(mounted: false)])
    manager.disksRefreshed([full(mounted: true)])
    XCTAssertEqual(center.added.count, 2)
    defaults.set(false, forKey: LowSpaceRules.enabledKey)
    manager.disksRefreshed([full(mounted: false)])
    manager.disksRefreshed([full(mounted: true)])
    XCTAssertEqual(center.added.count, 2)
  }

  func testAlmostFullNetworkShareIsAnnouncedOncePerMountWhenTheWarningIsOn() {
    let manager = makeManager()
    let nas = UUID()
    let full = [nas: ShareUsage(totalBytes: 2_000, freeBytes: 100)]
    let names = [nas: "NAS"]
    manager.sharesRefreshed(usage: full, mountedShareIDs: [nas], names: names)
    XCTAssertTrue(center.added.isEmpty)
    manager.isEnabled = true
    manager.sharesRefreshed(usage: full, mountedShareIDs: [nas], names: names)
    manager.sharesRefreshed(usage: full, mountedShareIDs: [nas], names: names)
    XCTAssertEqual(center.added.map(\.identifier), ["lowSpace.share.\(nas.uuidString)"])
    XCTAssertTrue(center.added.first?.content.body.contains("NAS") ?? false)
    manager.sharesRefreshed(usage: [:], mountedShareIDs: [], names: names)
    manager.sharesRefreshed(usage: full, mountedShareIDs: [nas], names: names)
    XCTAssertEqual(center.added.count, 2)
    defaults.set(false, forKey: LowSpaceRules.enabledKey)
    manager.sharesRefreshed(usage: [:], mountedShareIDs: [], names: names)
    manager.sharesRefreshed(usage: full, mountedShareIDs: [nas], names: names)
    XCTAssertEqual(center.added.count, 2)
  }

  func testIsOffByDefaultAndReadsTheSavedSetting() {
    XCTAssertFalse(makeManager().isEnabled)
    defaults.set(true, forKey: NotificationManager.enabledKey)
    XCTAssertTrue(makeManager().isEnabled)
  }

  func testTurningOnSavesTheSettingAndAsksForPermissionOnce() {
    let manager = makeManager()
    manager.isEnabled = true
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
    XCTAssertTrue(manager.isDeniedBySystem)
    XCTAssertFalse(manager.canDeliver)
  }

  func testTurningOffSavesTheSettingWithoutAskingAgain() {
    let manager = makeManager()
    manager.isEnabled = true
    manager.isEnabled = false
    XCTAssertFalse(defaults.bool(forKey: NotificationManager.enabledKey))
    XCTAssertEqual(center.authorizationRequests, 1)
  }

  func testStartReadsADeniedPermission() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    center.status = .denied
    let manager = makeManager()
    manager.start()
    XCTAssertTrue(center.delegateSet)
    XCTAssertTrue(manager.isDeniedBySystem)
    XCTAssertFalse(manager.canDeliver)
  }

  func testStartReadsAGrantedPermission() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    center.status = .authorized
    let manager = makeManager()
    manager.start()
    XCTAssertFalse(manager.isDeniedBySystem)
    XCTAssertTrue(manager.canDeliver)
  }

  func testStartAsksAgainWhenThePromptWasNeverAnswered() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    center.status = .notDetermined
    let manager = makeManager()
    manager.start()
    XCTAssertEqual(center.authorizationRequests, 1)
    XCTAssertTrue(manager.canDeliver)
  }

  func testPermissionIsAppliedOnlyOnTheMainThreadHops() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    center.status = .notDetermined
    var pending: [() -> Void] = []
    let manager = NotificationManager(
      center: center, defaults: defaults, activationNotifications: activation,
      performOnMain: { pending.append($0) })
    manager.start()
    XCTAssertEqual(center.authorizationRequests, 0)
    // Status read, then the prompt's answer: two hops.
    var hops = 0
    while !pending.isEmpty {
      pending.removeFirst()()
      hops += 1
      if hops == 1 { XCTAssertFalse(manager.canDeliver) }
    }
    XCTAssertEqual(hops, 2)
    XCTAssertEqual(center.authorizationRequests, 1)
    XCTAssertTrue(manager.canDeliver)
  }

  func testBecomingActiveReadsAPermissionChangedInSystemSettings() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    center.status = .authorized
    let manager = makeManager()
    manager.start()
    XCTAssertTrue(manager.canDeliver)
    center.status = .denied
    activation.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(manager.isDeniedBySystem)
    XCTAssertFalse(manager.canDeliver)
    // With the setting off, becoming active doesn't check again.
    manager.isEnabled = false
    center.status = .authorized
    activation.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    XCTAssertTrue(manager.isDeniedBySystem)
  }

  func testStartDoesNothingWhileTheSettingIsOff() {
    center.status = .denied
    let manager = makeManager()
    manager.start()
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
    manager.sleepUnmountTimedOut()
    XCTAssertEqual(center.added.map(\.identifier), ["sleepUnmount"])
    XCTAssertTrue(manager.idleUnmounted(message: "m", volumeID: "v"))
    XCTAssertEqual(center.added.last?.identifier, "idle.v")
  }

  // MARK: - Actions

  func testKeepAliveFailureUsesTheReconnectCategory() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    let manager = makeManager()
    manager.keepAliveResult(targetID: "a", name: "NAS", success: false)
    manager.keepAliveResult(targetID: "a", name: "NAS", success: false)
    XCTAssertEqual(
      center.added.last?.content.categoryIdentifier, NotificationAction.keepAliveFailedCategory)
  }

  func testOtherNotificationsUseTheDefaultCategory() {
    defaults.set(true, forKey: NotificationManager.enabledKey)
    let manager = makeManager()
    manager.sleepUnmountTimedOut()
    manager.blockedVolumeStillMounted(name: "Disk", volumeUUID: "u")
    XCTAssertEqual(center.added.count, 2)
    XCTAssertTrue(center.added.allSatisfy { $0.content.categoryIdentifier.isEmpty })
  }

  func testStartRegistersTheReconnectAction() {
    makeManager().start()
    let category = center.categories.first {
      $0.identifier == NotificationAction.keepAliveFailedCategory
    }
    XCTAssertEqual(category?.actions.map(\.identifier), [NotificationAction.reconnectActionID])
  }

  func testActionIdentifiersResolve() {
    XCTAssertEqual(
      NotificationAction.resolve(actionIdentifier: NotificationAction.reconnectActionID),
      .reconnectNow)
    XCTAssertEqual(
      NotificationAction.resolve(actionIdentifier: UNNotificationDefaultActionIdentifier),
      .openPopover)
    XCTAssertEqual(
      NotificationAction.resolve(actionIdentifier: UNNotificationDismissActionIdentifier), .none)
  }

  func testHandleResponseRunsTheMatchingAction() {
    let manager = makeManager()
    var reconnects = 0
    var opens = 0
    manager.reconnectNow = { reconnects += 1 }
    manager.openPopover = { opens += 1 }
    manager.handleResponse(actionIdentifier: NotificationAction.reconnectActionID)
    XCTAssertEqual([reconnects, opens], [1, 0])
    manager.handleResponse(actionIdentifier: UNNotificationDefaultActionIdentifier)
    XCTAssertEqual([reconnects, opens], [1, 1])
    manager.handleResponse(actionIdentifier: UNNotificationDismissActionIdentifier)
    XCTAssertEqual([reconnects, opens], [1, 1])
  }
}
