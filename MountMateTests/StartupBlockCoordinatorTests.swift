import XCTest

@testable import MountMate

/// Runs the reconcile logic against a fake /etc/fstab and a temporary
/// `UserDefaults` suite: nothing here reads or writes the real /etc/fstab or
/// asks for an administrator password.
final class StartupBlockCoordinatorTests: XCTestCase {
  private let uuid = "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "StartupBlockCoordinatorTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  private final class FakeAccess: StartupBlockFstabAccess {
    var contents = ""
    var eligibility: FstabRules.StartupBlockEligibility = .eligible(fileSystemType: "apfs")
    /// Errors thrown by successive `install` calls; empty = succeed.
    var installErrors: [Error] = []
    private(set) var snapshotLoads = 0
    private(set) var installed: [String] = []

    func readContents() -> String { contents }
    func loadSnapshot() throws -> FstabWriter.Snapshot {
      snapshotLoads += 1
      return FstabWriter.Snapshot(contents: contents, raw: Data(contents.utf8))
    }
    func install(_ newContents: String, expectedCurrent: Data) throws {
      installed.append(newContents)
      if !installErrors.isEmpty { throw installErrors.removeFirst() }
      contents = newContents
    }
    func startupBlockEligibility(forVolumeUUID uuid: String) -> FstabRules.StartupBlockEligibility {
      eligibility
    }
  }

  private final class FakeHost: StartupBlockHost {
    var enabled = true
    var blocked: [ManagedVolumeInfo] = []
    private(set) var ruleUUIDs: Set<String>?
    private(set) var feedback: [String] = []
    private(set) var failures: [(title: String, message: String)] = []
    private(set) var progress: [Bool] = []

    func startupBlockState() -> (enabled: Bool, blockedInfos: [ManagedVolumeInfo]) {
      (enabled, blocked)
    }
    func startupBlockUpdateInProgress(_ inProgress: Bool) { progress.append(inProgress) }
    func startupBlockRulesDidChange(volumeUUIDs: Set<String>) { ruleUUIDs = volumeUUIDs }
    func startupBlockShowFeedback(_ message: String) { feedback.append(message) }
    func startupBlockDidFail(title: String, message: String) {
      failures.append((title, message))
    }
  }

  private func makeCoordinator(
    access: FakeAccess, host: FakeHost, scheduleDelay: TimeInterval = 0.05
  ) -> StartupBlockCoordinator {
    StartupBlockCoordinator(
      defaults: defaults, access: access, host: host, scheduleDelay: scheduleDelay)
  }

  private var blockedInfo: ManagedVolumeInfo {
    ManagedVolumeInfo(volumeUUID: uuid, diskUUID: "DISK", name: "Backup")
  }

  private func error(code: Int) -> NSError {
    NSError(domain: "MountMate", code: code)
  }

  /// Waits until the coordinator's queue and the main-thread hops after it
  /// have finished.
  private func drain(_ coordinator: StartupBlockCoordinator) {
    let queueDone = expectation(description: "queue drained")
    coordinator.queue.async { queueDone.fulfill() }
    wait(for: [queueDone], timeout: 5)
    let mainDone = expectation(description: "main drained")
    DispatchQueue.main.async { mainDone.fulfill() }
    wait(for: [mainDone], timeout: 5)
  }

  private func reconcile(
    _ coordinator: StartupBlockCoordinator, userInitiated: Bool, silentOnCancel: Bool = false,
    fromToggle: Bool = false
  ) -> Bool? {
    var result: Bool?
    let done = expectation(description: "reconcile completion")
    coordinator.reconcile(
      userInitiated: userInitiated, silentOnCancel: silentOnCancel, fromToggle: fromToggle
    ) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    drain(coordinator)
    return result
  }

  func testAddsRuleForConnectedBlockedVolumeWhenEnabled() {
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    let coordinator = makeCoordinator(access: access, host: host)

    XCTAssertEqual(reconcile(coordinator, userInitiated: true, fromToggle: true), true)

    XCTAssertEqual(access.installed.count, 1)
    XCTAssertTrue(access.installed[0].contains("UUID=\(uuid) none apfs rw,noauto"))
    XCTAssertEqual(host.ruleUUIDs, [uuid])
    XCTAssertEqual(host.progress, [true, false])
    XCTAssertEqual(host.feedback.count, 1)
  }

  func testRemovesRuleWhenSettingIsOff() {
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    let coordinator = makeCoordinator(access: access, host: host)
    _ = reconcile(coordinator, userInitiated: true)
    XCTAssertEqual(host.ruleUUIDs, [uuid])

    host.enabled = false
    XCTAssertEqual(reconcile(coordinator, userInitiated: true), true)

    XCTAssertEqual(access.installed.count, 2)
    XCTAssertFalse(access.contents.contains("UUID=\(uuid)"))
    XCTAssertEqual(host.ruleUUIDs, [])
  }

  func testDoesNotWriteWhenNothingChanges() {
    let access = FakeAccess()
    let host = FakeHost()
    host.enabled = false
    let coordinator = makeCoordinator(access: access, host: host)

    XCTAssertEqual(reconcile(coordinator, userInitiated: false), true)

    XCTAssertTrue(access.installed.isEmpty)
    XCTAssertEqual(host.ruleUUIDs, [])
  }

  func testNotConnectedAndIneligibleVolumesGetNoRule() {
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    let coordinator = makeCoordinator(access: access, host: host)

    access.eligibility = .notConnected
    XCTAssertEqual(reconcile(coordinator, userInitiated: false), true)
    access.eligibility = .ineligible("system volume")
    XCTAssertEqual(reconcile(coordinator, userInitiated: false), true)

    XCTAssertTrue(access.installed.isEmpty)
  }

  func testFailedBackgroundUpdateIsDeclinedUntilTheNextUserAction() {
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    access.installErrors = [error(code: 4)]
    let coordinator = makeCoordinator(access: access, host: host)

    XCTAssertEqual(reconcile(coordinator, userInitiated: false), false)
    XCTAssertTrue(defaults.bool(forKey: "startupBlockBackgroundDeclined"))
    XCTAssertTrue(host.failures.isEmpty, "background updates never show an alert")

    // Declined: a background reconcile does not even read /etc/fstab.
    let loadsBefore = access.snapshotLoads
    coordinator.reconcile(userInitiated: false)
    drain(coordinator)
    XCTAssertEqual(access.snapshotLoads, loadsBefore)

    // A user action clears the flag and tries again.
    XCTAssertEqual(reconcile(coordinator, userInitiated: true), true)
    XCTAssertFalse(defaults.bool(forKey: "startupBlockBackgroundDeclined"))
    XCTAssertEqual(host.ruleUUIDs, [uuid])
  }

  func testDeclinedFlagPersistsAcrossCoordinators() {
    defaults.set(true, forKey: "startupBlockBackgroundDeclined")
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    let coordinator = makeCoordinator(access: access, host: host)

    coordinator.reconcile(userInitiated: false)
    drain(coordinator)

    XCTAssertEqual(access.snapshotLoads, 0)
  }

  func testCancelledPromptIsSilentOnlyWhenAskedTo() {
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    let coordinator = makeCoordinator(access: access, host: host)

    access.installErrors = [error(code: 4)]
    XCTAssertEqual(
      reconcile(coordinator, userInitiated: true, silentOnCancel: true, fromToggle: true), false)
    XCTAssertTrue(host.failures.isEmpty)

    access.installErrors = [error(code: 4)]
    XCTAssertEqual(reconcile(coordinator, userInitiated: true), false)
    XCTAssertEqual(host.failures.count, 1)
  }

  func testRetriesOnceWhenFstabChangedBetweenReadAndWrite() {
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    access.installErrors = [error(code: FstabWriter.fstabChangedErrorCode)]
    let coordinator = makeCoordinator(access: access, host: host)

    XCTAssertEqual(reconcile(coordinator, userInitiated: true), true)
    XCTAssertEqual(access.installed.count, 2)
    XCTAssertEqual(host.ruleUUIDs, [uuid])
  }

  func testGivesUpWhenFstabKeepsChanging() {
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    access.installErrors = Array(
      repeating: error(code: FstabWriter.fstabChangedErrorCode), count: 5)
    let coordinator = makeCoordinator(access: access, host: host)

    XCTAssertEqual(reconcile(coordinator, userInitiated: true), false)
    XCTAssertEqual(access.installed.count, 2)
    XCTAssertEqual(host.failures.count, 1)
  }

  func testScheduledReconcilesAreCoalescedAndSkippedWhenOff() {
    let access = FakeAccess()
    let host = FakeHost()
    host.blocked = [blockedInfo]
    let coordinator = makeCoordinator(access: access, host: host, scheduleDelay: 0.05)

    host.enabled = false
    coordinator.scheduleReconcile()
    let idle = expectation(description: "idle")
    idle.isInverted = true
    wait(for: [idle], timeout: 0.3)
    drain(coordinator)
    XCTAssertEqual(access.snapshotLoads, 0)

    host.enabled = true
    coordinator.scheduleReconcile()
    coordinator.scheduleReconcile()
    coordinator.scheduleReconcile()
    let later = expectation(description: "delay elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { later.fulfill() }
    wait(for: [later], timeout: 5)
    drain(coordinator)

    XCTAssertEqual(access.snapshotLoads, 1)
    XCTAssertEqual(access.installed.count, 1)
  }

  func testLaunchReconcileOnlyRunsWhenThereIsSomethingToDo() {
    let access = FakeAccess()
    let host = FakeHost()
    let coordinator = makeCoordinator(access: access, host: host)

    coordinator.reconcileAtLaunch(enabled: false, knownRuleUUIDs: [])
    drain(coordinator)
    XCTAssertEqual(access.snapshotLoads, 0)

    coordinator.reconcileAtLaunch(enabled: false, knownRuleUUIDs: [uuid])
    drain(coordinator)
    XCTAssertEqual(access.snapshotLoads, 1)
  }

  // MARK: - PersistenceManager(defaults:)

  func testPersistenceManagerReadsSettingsFromItsOwnDefaults() {
    defaults.set(true, forKey: "blockAtStartup")
    defaults.set(["DISK-\(uuid)", "NONE-disk4s1"], forKey: "pinnedVolumeIDs")
    let access = FakeAccess()
    access.contents = "# MountMate block: DISK-\(uuid)\nUUID=\(uuid) none apfs rw,noauto\n"

    let manager = PersistenceManager(defaults: defaults, fstabAccess: access)

    XCTAssertTrue(manager.blockAtStartup)
    XCTAssertEqual(manager.fstabBlockedVolumeUUIDs, [uuid])
    XCTAssertEqual(manager.pinnedVolumeIDs, ["DISK-\(uuid)"], "non-UUID pins are dropped on load")
  }

  func testTurningBlockAtStartupOnRollsBackWhenThePromptIsCancelled() {
    let access = FakeAccess()
    access.installErrors = [error(code: 4)]
    let manager = PersistenceManager(defaults: defaults, fstabAccess: access)
    manager.blockedVolumes = [blockedInfo]

    manager.setBlockAtStartup(true)
    XCTAssertTrue(manager.blockAtStartup)
    XCTAssertTrue(defaults.bool(forKey: "blockAtStartup"))

    let deadline = Date().addingTimeInterval(5)
    while manager.blockAtStartup && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    XCTAssertFalse(manager.blockAtStartup)
    XCTAssertFalse(defaults.bool(forKey: "blockAtStartup"))
  }
}
