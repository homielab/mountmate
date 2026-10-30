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

  func testNextRetryDateForVolumeFollowsBackoffAndReconnectNowClearsIt() {
    let manager = KeepAliveManager.shared
    let id = "test-volume-\(UUID().uuidString)"
    XCTAssertNil(manager.nextRetryDate(forVolumeID: id))

    manager.recordAttempt(volumeID: id)
    let next = manager.nextRetryDate(forVolumeID: id)
    XCTAssertGreaterThan(next ?? .distantPast, Date())

    manager.sweepNow(resetBackoff: true)
    let done = expectation(description: "sweep scheduled")
    DispatchQueue.main.async { done.fulfill() }
    wait(for: [done], timeout: 5)
    XCTAssertNil(manager.nextRetryDate(forVolumeID: id))
  }

  func testAutomaticMountKeepsVolumeBackoffAndUserMountResetsIt() {
    let manager = KeepAliveManager.shared
    let uuid = UUID().uuidString
    let volume = Volume(
      id: uuid, deviceIdentifier: "disk9s1", diskUUID: nil, name: "Backoff Drive",
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: "exfat", usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
    let key = volume.compositeId ?? ""
    XCTAssertFalse(key.isEmpty)

    manager.recordAttempt(volumeID: key)
    manager.resumeIfUserInitiated(volume: volume, isUserInitiated: false)
    manager.recordAttempt(volumeID: key)
    XCTAssertEqual(manager.retryAttempt(forVolumeID: key), 2)
    XCTAssertNotNil(manager.nextRetryDate(forVolumeID: key))

    manager.resumeIfUserInitiated(volume: volume, isUserInitiated: true)
    XCTAssertEqual(manager.retryAttempt(forVolumeID: key), 0)
    XCTAssertNil(manager.nextRetryDate(forVolumeID: key))
  }

  // MARK: - Network changes

  private final class FakeNetworkMonitor: NetworkChangeMonitoring {
    var onChange: ((NetworkPathSnapshot) -> Void)?
    private(set) var isStarted = false
    func start() { isStarted = true }
    func stop() { isStarted = false }
    func send(_ path: NetworkPathSnapshot) { onChange?(path) }
  }

  private let wifi = InterfaceSnapshot(name: "en0", type: .wifi)
  private let ethernet = InterfaceSnapshot(name: "en5", type: .wiredEthernet)

  private func path(_ interfaces: [InterfaceSnapshot], satisfied: Bool = true)
    -> NetworkPathSnapshot
  {
    NetworkPathSnapshot(isSatisfied: satisfied, interfaces: interfaces)
  }

  func testInjectedMonitorIsStartedAndStoppedWithTheManager() {
    let monitor = FakeNetworkMonitor()
    var manager: KeepAliveManager? = KeepAliveManager(networkMonitor: monitor)
    XCTAssertTrue(monitor.isStarted)
    XCTAssertNotNil(manager)
    manager = nil
    XCTAssertFalse(monitor.isStarted)
  }

  func testRemountRunsOnlyWhenTheInterfaceChanges() {
    let monitor = FakeNetworkMonitor()
    var remounts = 0
    let manager = KeepAliveManager(
      networkMonitor: monitor, interfaceChangeAction: { remounts += 1 })
    manager.isEnabled = true
    manager.remountOnNetworkChange = true

    monitor.send(path([wifi]))  // first observation: sweep, no remount
    monitor.send(path([wifi]))  // unchanged
    XCTAssertEqual(remounts, 0)
    monitor.send(path([ethernet, wifi]))  // Ethernet becomes primary
    XCTAssertEqual(remounts, 1)
    monitor.send(path([ethernet]))  // Wi-Fi left, Ethernet stays
    XCTAssertEqual(remounts, 1)
    monitor.send(path([], satisfied: false))  // offline
    monitor.send(path([wifi]))  // back online: sweep, no remount
    XCTAssertEqual(remounts, 1)
  }

  func testNoRemountWhenTheSettingIsOffOrKeepAliveIsDisabled() {
    let monitor = FakeNetworkMonitor()
    var remounts = 0
    let manager = KeepAliveManager(
      networkMonitor: monitor, interfaceChangeAction: { remounts += 1 })
    let enabled = manager.isEnabled
    let setting = manager.remountOnNetworkChange
    defer {
      manager.isEnabled = enabled
      manager.remountOnNetworkChange = setting
    }

    manager.isEnabled = true
    manager.remountOnNetworkChange = false
    monitor.send(path([wifi]))
    monitor.send(path([ethernet]))
    XCTAssertEqual(remounts, 0)

    manager.remountOnNetworkChange = true
    manager.isEnabled = false
    monitor.send(path([wifi]))
    XCTAssertEqual(remounts, 0)
  }

  // MARK: - Login mounts with Keep Alive off

  /// Sets Keep Alive and restores the stored setting afterwards.
  private func setKeepAlive(_ on: Bool, on manager: KeepAliveManager) {
    let key = "keepAliveEnabled"
    let stored = UserDefaults.standard.object(forKey: key) as? Bool
    addTeardownBlock {
      if let stored {
        UserDefaults.standard.set(stored, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    manager.isEnabled = on
  }

  func testKeepAliveOffRetriesTheFailedLoginMountWhenTheNetworkComesBack() {
    let share = NetworkShare(
      name: "NAS", server: "nas.local", sharePath: "media", username: "me",
      mountAtLogin: true, keepMounted: false)
    var mounts = 0
    let retrier = LoginMountRetrier(
      shares: { [share] }, isMounted: { _ in false }, isSuppressed: { _ in false },
      mount: { _, completion in
        mounts += 1
        completion(false, nil)
      })
    let monitor = FakeNetworkMonitor()
    let manager = KeepAliveManager(
      networkMonitor: monitor, sweepAction: {}, loginMountRetryAction: { retrier.retry() })
    setKeepAlive(false, on: manager)

    retrier.mountAtLaunch()  // Wi-Fi not up yet: fails
    XCTAssertEqual(mounts, 1)
    monitor.send(path([], satisfied: false))
    XCTAssertEqual(mounts, 1)
    monitor.send(path([wifi]))
    XCTAssertEqual(mounts, 2)
  }

  func testKeepAliveOnLeavesLoginSharesToTheSweep() {
    var loginRetries = 0
    var sweeps = 0
    let monitor = FakeNetworkMonitor()
    let manager = KeepAliveManager(
      networkMonitor: monitor, sweepAction: { sweeps += 1 },
      loginMountRetryAction: { loginRetries += 1 })
    setKeepAlive(true, on: manager)
    drainMain()
    sweeps = 0

    monitor.send(path([], satisfied: false))
    monitor.send(path([wifi]))
    drainMain()
    XCTAssertEqual(loginRetries, 0)
    XCTAssertEqual(sweeps, 1)
  }

  // MARK: - Sweep requested while a sweep runs

  /// A manager whose sweep only counts runs, with Keep Alive on. Restores the
  /// stored setting afterwards (`isEnabled` writes UserDefaults).
  private func queueingManager(runs: @escaping () -> Void) -> KeepAliveManager {
    let key = "keepAliveEnabled"
    let stored = UserDefaults.standard.object(forKey: key) as? Bool
    addTeardownBlock {
      if let stored {
        UserDefaults.standard.set(stored, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    let manager = KeepAliveManager(networkMonitor: FakeNetworkMonitor(), sweepAction: runs)
    manager.isEnabled = true
    return manager
  }

  /// Simulates a sweep in flight (e.g. stuck on an offline NAS).
  private func startFakeSweep(_ manager: KeepAliveManager) -> Int {
    manager.sweepGeneration &+= 1
    manager.isSweeping = true
    return manager.sweepGeneration
  }

  func testRequestsDuringASweepRunExactlyOneMoreSweepWhenItFinishes() {
    var runs = 0
    let manager = queueingManager { runs += 1 }
    drainMain()
    runs = 0
    let generation = startFakeSweep(manager)

    // Network back, then wake, then "Reconnect Now" while the sweep hangs.
    manager.sweepNow(resetBackoff: true)
    manager.sweepNow(resetBackoff: true)
    manager.sweepNow()
    drainMain()
    XCTAssertEqual(runs, 0)
    XCTAssertTrue(manager.sweepPending)

    manager.finishSweep(generation: generation)
    XCTAssertEqual(runs, 1)
    XCTAssertFalse(manager.sweepPending)
    XCTAssertFalse(manager.pendingSweepResetsBackoff)

    // A late completion of the same sweep runs nothing more.
    manager.finishSweep(generation: generation)
    XCTAssertEqual(runs, 1)
  }

  func testRequestWhenIdleSweepsAtOnceAndQueuesNothing() {
    var runs = 0
    let manager = queueingManager { runs += 1 }
    drainMain()
    runs = 0

    manager.sweepNow()
    drainMain()
    XCTAssertEqual(runs, 1)
    XCTAssertFalse(manager.sweepPending)
  }

  func testQueuedResetBackoffClearsDelaysRecordedByTheRunningSweep() {
    let manager = queueingManager {}
    let id = UUID()
    drainMain()
    let generation = startFakeSweep(manager)
    manager.recordAttempt(shareID: id)

    manager.sweepNow(resetBackoff: true)
    drainMain()
    XCTAssertTrue(manager.pendingSweepResetsBackoff)
    // The running sweep's attempt on the offline server fails afterwards.
    manager.recordAttempt(shareID: id)
    XCTAssertNotNil(manager.nextRetryDate(forShareID: id))

    manager.finishSweep(generation: generation)
    XCTAssertNil(manager.nextRetryDate(forShareID: id))
    XCTAssertEqual(manager.retryAttempt(forShareID: id), 2)
  }

  func testQueuedSweepWithoutResetKeepsBackoff() {
    let manager = queueingManager {}
    let id = UUID()
    drainMain()
    let generation = startFakeSweep(manager)

    manager.sweepNow()
    drainMain()
    manager.recordAttempt(shareID: id)
    manager.finishSweep(generation: generation)
    XCTAssertNotNil(manager.nextRetryDate(forShareID: id))
  }

  func testNothingIsQueuedWhenKeepAliveIsOff() {
    var runs = 0
    let manager = queueingManager { runs += 1 }
    drainMain()
    runs = 0

    // Turned off while a request waits: it is dropped.
    var generation = startFakeSweep(manager)
    manager.sweepNow(resetBackoff: true)
    drainMain()
    XCTAssertTrue(manager.sweepPending)
    manager.isEnabled = false
    XCTAssertFalse(manager.sweepPending)
    manager.finishSweep(generation: generation)
    XCTAssertEqual(runs, 0)

    // Already off: a request queues nothing.
    generation = startFakeSweep(manager)
    manager.sweepNow(resetBackoff: true)
    drainMain()
    XCTAssertFalse(manager.sweepPending)
    manager.finishSweep(generation: generation)
    XCTAssertEqual(runs, 0)
  }

  // MARK: - Remounting volumes

  private func remountTestVolume() -> Volume {
    Volume(
      id: "remount-test", deviceIdentifier: "disk9s1", diskUUID: nil, name: "Slow Drive",
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: "exfat", usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  func testSlowRemountIsReportedWhenItFinishesNotAfterAFixedDelay() {
    let started = Date()
    let done = expectation(description: "remount result")
    var elapsed: TimeInterval = 0
    var result: Result<Void, Error>?
    // A spinning drive that needs 4 s (longer than the old fixed 3 s wait).
    KeepAliveManager.shared.remount(
      volume: remountTestVolume(),
      mounter: { _, completion in
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { completion(.success(())) }
      },
      timeout: 30,
      completion: {
        elapsed = Date().timeIntervalSince(started)
        result = $0
        done.fulfill()
      })
    wait(for: [done], timeout: 15)
    guard case .success = result else { return XCTFail("slow successful mount must not fail") }
    XCTAssertGreaterThanOrEqual(elapsed, 3.9)
  }

  func testFailedRemountIsReportedAsFailure() {
    let done = expectation(description: "remount result")
    var result: Result<Void, Error>?
    KeepAliveManager.shared.remount(
      volume: remountTestVolume(),
      mounter: { _, completion in completion(.failure(MountFailure(message: "busy"))) },
      completion: {
        result = $0
        done.fulfill()
      })
    wait(for: [done], timeout: 5)
    guard case .failure = result else { return XCTFail("expected a failure") }
  }

  func testRemountThatNeverFinishesTimesOutOnceAndIgnoresLateCompletion() {
    let done = expectation(description: "remount result")
    var results = 0
    var lateCompletion: ((Result<Void, Error>) -> Void)?
    KeepAliveManager.shared.remount(
      volume: remountTestVolume(),
      mounter: { _, completion in lateCompletion = completion },
      timeout: 0.2,
      completion: { result in
        results += 1
        if case .success = result { XCTFail("timeout must be a failure") }
        done.fulfill()
      })
    wait(for: [done], timeout: 5)
    lateCompletion?(.success(()))
    let settle = expectation(description: "settle")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
    wait(for: [settle], timeout: 2)
    XCTAssertEqual(results, 1)
  }

  // MARK: - Reconnecting state cleanup

  /// Waits for the main-queue hops `recordResult` does.
  private func drainMain() {
    let done = expectation(description: "main drained")
    DispatchQueue.main.async { done.fulfill() }
    wait(for: [done], timeout: 2)
  }

  private func iconState(of manager: KeepAliveManager) -> MenuBarIconState {
    MenuBarIconState(
      isUnmountingAll: false, busyVolume: false, busyEject: false, error: false,
      reconnecting: !manager.reconnectingShareIDs.isEmpty
        || !manager.reconnectingVolumeIDs.isEmpty)
  }

  func testRemovedShareLeavesReconnectingAndIconGoesIdle() {
    let manager = KeepAliveManager.shared
    let id = UUID()
    manager.recordAttempt(shareID: id)
    manager.recordResult(shareID: id, name: "Gone", success: false)
    drainMain()
    XCTAssertTrue(manager.reconnectingShareIDs.contains(id))
    XCTAssertEqual(iconState(of: manager), .reconnecting)

    // The share was deleted or is no longer "Keep Mounted".
    manager.reconcileTargets(validShareIDs: [], validVolumeIDs: [])
    XCTAssertFalse(manager.reconnectingShareIDs.contains(id))
    XCTAssertEqual(manager.retryAttempt(forShareID: id), 0)
    XCTAssertEqual(iconState(of: manager), .idle)
  }

  func testUnpluggedOrNoLongerKeptVolumeLeavesReconnecting() {
    let manager = KeepAliveManager.shared
    let id = "KeepAliveTest-\(UUID().uuidString)"
    manager.recordResult(volumeID: id, name: "Drive", success: false)
    drainMain()
    XCTAssertEqual(iconState(of: manager), .reconnecting)

    // Still a keep-alive target and plugged in: stays.
    manager.reconcileTargets(validShareIDs: [], validVolumeIDs: [id])
    XCTAssertTrue(manager.reconnectingVolumeIDs.contains(id))

    // Pulled out or Keep Alive turned off.
    manager.reconcileTargets(validShareIDs: [], validVolumeIDs: [])
    XCTAssertFalse(manager.reconnectingVolumeIDs.contains(id))
    XCTAssertEqual(iconState(of: manager), .idle)
  }

  func testSuppressedVolumeFailureIsNotReconnecting() {
    let manager = KeepAliveManager.shared
    let volume = Volume(
      id: UUID().uuidString, deviceIdentifier: "disk9s1", diskUUID: nil, name: "Ejected",
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: "exfat", usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
    let id = volume.compositeId!
    manager.suppress(volume: volume)
    defer { manager.resume(volume: volume) }
    manager.recordResult(volumeID: id, name: "Ejected", success: false)
    drainMain()
    XCTAssertFalse(manager.reconnectingVolumeIDs.contains(id))
  }

  private func suppressionTestVolume() -> Volume {
    Volume(
      id: UUID().uuidString, deviceIdentifier: "disk9s1", diskUUID: nil, name: "Busy",
      isMounted: true, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: "exfat", usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  func testFailedUnmountLiftsTheSuppressionItAdded() {
    let manager = KeepAliveManager.shared
    let volume = suppressionTestVolume()
    let id = volume.compositeId!
    defer { manager.resume(volume: volume) }
    let before = manager.suppressedVolumes(among: [volume])
    manager.suppress(volumes: [volume])
    XCTAssertTrue(manager.isSuppressed(volumeID: id))
    manager.unsuppress(volumes: [volume], keeping: before)
    XCTAssertFalse(manager.isSuppressed(volumeID: id))
  }

  func testSuccessfulUnmountKeepsTheSuppression() {
    let manager = KeepAliveManager.shared
    let volume = suppressionTestVolume()
    defer { manager.resume(volume: volume) }
    manager.suppress(volumes: [volume])
    // No unsuppress on success.
    XCTAssertTrue(manager.isSuppressed(volumeID: volume.compositeId!))
  }

  func testFailedUnmountKeepsASuppressionThatWasThereBefore() {
    let manager = KeepAliveManager.shared
    let volume = suppressionTestVolume()
    let other = suppressionTestVolume()
    defer {
      manager.resume(volume: volume)
      manager.resume(volume: other)
    }
    manager.suppress(volume: volume)
    let before = manager.suppressedVolumes(among: [volume, other])
    XCTAssertEqual(before.count, 1)
    manager.suppress(volumes: [volume, other])
    manager.unsuppress(volumes: [volume, other], keeping: before)
    XCTAssertTrue(manager.isSuppressed(volumeID: volume.compositeId!))
    XCTAssertFalse(manager.isSuppressed(volumeID: other.compositeId!))
  }
}
