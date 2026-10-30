//  Created by homielab.com

import XCTest

@testable import MountMate

final class WakeRemountManagerTests: XCTestCase {
  private final class ManualScheduler {
    var delays: [TimeInterval] = []
    var pending: [() -> Void] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
      delays.append(delay)
      pending.append(work)
    }

    func fireNext() {
      guard !pending.isEmpty else { return }
      let next = pending.removeFirst()
      next()
    }
  }

  private let uuidA = "11111111-1111-1111-1111-111111111111"
  private let uuidB = "22222222-2222-2222-2222-222222222222"

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var scheduler: ManualScheduler!

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "WakeRemountManagerTests-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    scheduler = ManualScheduler()
  }

  override func tearDown() {
    if let suiteName {
      defaults?.removePersistentDomain(forName: suiteName)
    }
    defaults = nil
    scheduler = nil
    super.tearDown()
  }

  private func volume(
    _ uuid: String, name: String, id: String = "disk9s1", isMounted: Bool = false
  ) -> Volume {
    Volume(
      id: uuid, deviceIdentifier: id, diskUUID: nil, name: name, isMounted: isMounted,
      mountPoint: isMounted ? "/Volumes/\(name)" : nil, freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: nil, fileSystemType: "apfs", usagePercentage: nil,
      category: .user, isProtected: false, snapshots: [], storageError: nil)
  }

  func testSleepingAgainWhileRunningKeepsNewPlanAndIgnoresStaleWakeCallbacks() {
    var currentVolumes = [
      volume(uuidA, name: "A", id: "disk9s1"),
      volume(uuidB, name: "B", id: "disk9s2"),
    ]
    var mountedNames: [String] = []
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion(currentVolumes) },
      isBusy: { _ in false },
      mount: { volume, completion in
        mountedNames.append(volume.name)
        completion(true)
      })

    // First sleep + wake starts running (attempt 0 is waiting for the 3 s delay).
    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)])
    manager.handleWake()
    XCTAssertTrue(manager.isRunning)
    XCTAssertEqual(scheduler.delays, [3])

    // A duplicate wake notification while already running keeps the plan intact.
    manager.handleWake()
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A"])
    XCTAssertEqual(scheduler.delays, [3])

    // The Mac sleeps again within 13 s with volume B and wakes a second time.
    manager.begin(volumes: [volume(uuidB, name: "B", isMounted: true)])
    manager.handleWake()
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["B"])
    XCTAssertTrue(manager.isRunning)
    XCTAssertEqual(scheduler.delays, [3, 3])

    // The first wake's 3 s timer fires late: it must exit without touching plan B.
    scheduler.fireNext()
    XCTAssertTrue(mountedNames.isEmpty)
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["B"])
    XCTAssertTrue(manager.isRunning)

    // The second wake's 3 s timer mounts B and finishes the plan.
    currentVolumes = [volume(uuidB, name: "B", id: "disk9s2", isMounted: false)]
    scheduler.fireNext()
    XCTAssertEqual(mountedNames, ["B"])
    XCTAssertNil(manager.plan)
    XCTAssertFalse(manager.isRunning)
  }

  func testStaleAttemptAfterFirstAttemptDoesNotClearNewWakePlan() {
    let unmountedA = volume(uuidA, name: "A", id: "disk9s1", isMounted: false)
    let unmountedB = volume(uuidB, name: "B", id: "disk9s2", isMounted: false)
    var currentVolumes = [unmountedA]
    var shouldSucceed = false
    var mountedNames: [String] = []

    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion(currentVolumes) },
      isBusy: { _ in false },
      mount: { volume, completion in
        mountedNames.append(volume.name)
        completion(shouldSucceed)
      })

    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)])
    manager.handleWake()
    // Attempt 0 at +3 s fails, scheduling attempt 1 at +10 s.
    scheduler.fireNext()
    XCTAssertEqual(mountedNames, ["A"])
    XCTAssertEqual(scheduler.delays, [3, 10])
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A"])

    // Before the +10 s attempt fires, the Mac sleeps and wakes with volume B.
    currentVolumes = [unmountedB]
    shouldSucceed = true
    manager.begin(volumes: [volume(uuidB, name: "B", isMounted: true)])
    manager.handleWake()
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["B"])

    // Old +10 s attempt fires first: must not mount A or clear B's plan.
    scheduler.fireNext()
    XCTAssertEqual(mountedNames, ["A"])
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["B"])
    XCTAssertTrue(manager.isRunning)

    // New wake's +3 s attempt mounts B.
    scheduler.fireNext()
    XCTAssertEqual(mountedNames, ["A", "B"])
    XCTAssertNil(manager.plan)
    XCTAssertFalse(manager.isRunning)
  }

  func testFailedMountStaysInPlanAndIsRetriedOnSecondAttempt() {
    let unmountedA = volume(uuidA, name: "A", id: "disk9s1", isMounted: false)
    var attempts = 0
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion([unmountedA]) },
      isBusy: { _ in false },
      mount: { _, completion in
        attempts += 1
        completion(attempts == 2)
      })

    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)])
    manager.handleWake()
    XCTAssertEqual(scheduler.delays, [3])

    // First attempt (+3 s) fails: A stays in the plan and +10 s is scheduled.
    scheduler.fireNext()
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A"])
    XCTAssertTrue(manager.isRunning)
    XCTAssertEqual(scheduler.delays, [3, 10])

    // Second attempt (+10 s) succeeds and clears the plan.
    scheduler.fireNext()
    XCTAssertEqual(attempts, 2)
    XCTAssertNil(manager.plan)
    XCTAssertFalse(manager.isRunning)
  }

  func testSlowDiskThatAppearsOnTheThirdAttemptIsMounted() {
    var currentVolumes: [Volume] = []
    var mounted: [String] = []
    var notified: [[String]] = []
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion(currentVolumes) },
      isBusy: { _ in false },
      mount: { volume, completion in
        mounted.append(volume.name)
        completion(true)
      },
      notifyNotRemounted: { notified.append($0) })

    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)])
    manager.handleWake()
    scheduler.fireNext()
    scheduler.fireNext()
    XCTAssertEqual(scheduler.delays, [3, 10, 30])
    XCTAssertTrue(mounted.isEmpty)

    currentVolumes = [volume(uuidA, name: "A")]
    scheduler.fireNext()
    XCTAssertEqual(mounted, ["A"])
    XCTAssertNil(manager.plan)
    XCTAssertFalse(manager.isRunning)
    XCTAssertTrue(notified.isEmpty)
  }

  func testDisksLeftAfterTheLastAttemptAreAnnouncedOnce() {
    var pendingMounts: [(Bool) -> Void] = []
    var notified: [[String]] = []
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { [uuidB] completion in completion([self.volume(uuidB, name: "B")]) },
      isBusy: { _ in false },
      mount: { _, completion in pendingMounts.append(completion) },
      notifyNotRemounted: { notified.append($0) })

    manager.begin(volumes: [
      volume(uuidA, name: "Backup", isMounted: true),
      volume(uuidB, name: "B", id: "disk9s2", isMounted: true),
    ])
    manager.handleWake()
    for _ in 0..<2 {
      scheduler.fireNext()
      pendingMounts.removeFirst()(false)
    }
    scheduler.fireNext()
    // The last mount is still running: nothing is announced yet.
    XCTAssertTrue(notified.isEmpty)
    XCTAssertTrue(manager.isRunning)

    pendingMounts.removeFirst()(true)
    XCTAssertEqual(notified, [["Backup"]])
    XCTAssertNil(manager.plan)
    XCTAssertFalse(manager.isRunning)
    XCTAssertTrue(scheduler.pending.isEmpty)
  }

  func testAPlanEmptiedByTheUserIsNotAnnounced() {
    var notified: [[String]] = []
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion([]) },
      isBusy: { _ in false },
      mount: { _, completion in completion(true) },
      notifyNotRemounted: { notified.append($0) })

    let a = volume(uuidA, name: "A", isMounted: true)
    manager.begin(volumes: [a])
    manager.handleWake()
    scheduler.fireNext()
    manager.forget([a])
    scheduler.fireNext()
    XCTAssertTrue(notified.isEmpty)
    XCTAssertNil(manager.plan)
    XCTAssertFalse(manager.isRunning)
  }

  func testBusyVolumeStaysInPlanForSecondAttempt() {
    let unmountedA = volume(uuidA, name: "A", id: "disk9s1", isMounted: false)
    var busy = true
    var mounted = 0
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion([unmountedA]) },
      isBusy: { _ in busy },
      mount: { _, completion in
        mounted += 1
        completion(true)
      })

    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)])
    manager.handleWake()

    // Busy at +3 s: skipped, kept in the plan for +10 s.
    scheduler.fireNext()
    XCTAssertEqual(mounted, 0)
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A"])
    XCTAssertEqual(scheduler.delays, [3, 10])

    busy = false
    scheduler.fireNext()
    XCTAssertEqual(mounted, 1)
    XCTAssertNil(manager.plan)
    XCTAssertFalse(manager.isRunning)
  }

  func testLateMountCompletionFromPreviousWakeDoesNotModifyNewWakePlan() {
    let unmountedA = volume(uuidA, name: "A", id: "disk9s1", isMounted: false)
    var pendingCompletion: ((Bool) -> Void)?
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion([unmountedA]) },
      isBusy: { _ in false },
      mount: { _, completion in
        pendingCompletion = completion
      })

    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)])
    manager.handleWake()
    scheduler.fireNext()
    XCTAssertNotNil(pendingCompletion)

    // Sleep and wake again with the same volume A before the first mount finished.
    let firstMountCompletion = pendingCompletion
    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)])
    manager.handleWake()
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A"])

    // The old mount finishes late: it must not remove A from the new wake's plan.
    firstMountCompletion?(true)
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A"])
    XCTAssertTrue(manager.isRunning)
  }

  func testLockPlanWaitsThroughWakeAndMountsAtUnlock() {
    let currentVolumes = [
      volume(uuidA, name: "A", id: "disk9s1"),
      volume(uuidB, name: "B", id: "disk9s2"),
    ]
    var mountedNames: [String] = []
    var screenLocked = true
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion(currentVolumes) },
      isBusy: { _ in false },
      mount: { volume, completion in
        mountedNames.append(volume.name)
        completion(true)
      })
    manager.waitsForUnlock = { screenLocked }

    // Lock unmounts A; the Mac then sleeps and the sleep unmount adds B.
    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)], merging: true)
    manager.begin(volumes: [volume(uuidB, name: "B", isMounted: true)], merging: true)
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A", "B"])

    // Wake with the screen still locked: nothing is scheduled, the plan stays.
    manager.handleWake()
    XCTAssertFalse(manager.isRunning)
    XCTAssertTrue(scheduler.delays.isEmpty)
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A", "B"])

    // Unlock mounts both.
    screenLocked = false
    manager.handleUnlock()
    scheduler.fireNext()
    XCTAssertEqual(mountedNames, ["A", "B"])
    XCTAssertNil(manager.plan)
    XCTAssertFalse(manager.isRunning)
  }

  func testBeginWithoutMergingReplacesThePlan() {
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion([]) },
      isBusy: { _ in false },
      mount: { _, completion in completion(true) })
    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)], merging: true)
    manager.begin(volumes: [volume(uuidB, name: "B", isMounted: true)])
    XCTAssertEqual(manager.plan?.entries.map(\.name), ["B"])
  }

  func testUnlockWithMountAgainOffMountsNothing() {
    var mountCount = 0
    defaults.set(false, forKey: WakeRemountManager.enabledKey)
    let manager = WakeRemountManager(
      defaults: defaults,
      schedule: { [scheduler] delay, work in scheduler!.schedule(delay, work) },
      refreshVolumes: { completion in completion([]) },
      isBusy: { _ in false },
      mount: { _, completion in
        mountCount += 1
        completion(true)
      })
    manager.begin(volumes: [volume(uuidA, name: "A", isMounted: true)], merging: true)
    manager.handleUnlock()
    XCTAssertNil(manager.plan)
    XCTAssertTrue(scheduler.delays.isEmpty)
    XCTAssertEqual(mountCount, 0)
  }

  // MARK: Eject

  private func disk(_ volumes: [Volume]) -> PhysicalDisk {
    PhysicalDisk(
      id: "disk9", diskUUID: nil, connectionType: "USB", name: "Backup", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: .physical, isRAIDSet: false,
      partitions: volumes, containers: [], storageError: nil)
  }

  func testASuccessfulEjectDropsTheDisksVolumesFromThePlan() {
    let manager = WakeRemountManager(defaults: defaults, schedule: { _, _ in })
    let a = volume(uuidA, name: "A", id: "disk9s1")
    let b = volume(uuidB, name: "B", id: "disk8s1")
    manager.begin(volumes: [a, b])

    DriveManager.forgetWakeRemount(afterEjecting: disk([a]), succeeded: true, wakeRemount: manager)

    XCTAssertEqual(manager.plan?.entries.map(\.name), ["B"])
  }

  func testAFailedEjectKeepsThePlan() {
    let manager = WakeRemountManager(defaults: defaults, schedule: { _, _ in })
    let a = volume(uuidA, name: "A", id: "disk9s1")
    manager.begin(volumes: [a])

    DriveManager.forgetWakeRemount(afterEjecting: disk([a]), succeeded: false, wakeRemount: manager)
    DriveManager.forgetWakeRemount(afterEjecting: nil, succeeded: true, wakeRemount: manager)

    XCTAssertEqual(manager.plan?.entries.map(\.name), ["A"])
  }
}
