//  Created by homielab.com

import XCTest

@testable import MountMate

/// Keep Alive checks that a share still in the mount table answers, and
/// reconnects it when it does not (NAS restarted, network or VPN changed).
final class KeepAliveStaleMountTests: XCTestCase {
  private final class FakeNetworkMonitor: NetworkChangeMonitoring {
    var onChange: ((NetworkPathSnapshot) -> Void)?
    func start() {}
    func stop() {}
  }

  /// A manager with Keep Alive on whose own sweeps do nothing. Restores the
  /// stored setting afterwards (`isEnabled` writes UserDefaults).
  private func makeManager(lowPowerMode: Bool = false) -> KeepAliveManager {
    let key = "keepAliveEnabled"
    let stored = UserDefaults.standard.object(forKey: key) as? Bool
    addTeardownBlock {
      if let stored {
        UserDefaults.standard.set(stored, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    let manager = KeepAliveManager(
      networkMonitor: FakeNetworkMonitor(), sweepAction: {},
      isLowPowerMode: { lowPowerMode })
    manager.isEnabled = true
    return manager
  }

  private func makeShare() -> NetworkShare {
    NetworkShare(
      name: "StaleTest-\(UUID().uuidString)", server: "invalid.example", sharePath: "x",
      username: "")
  }

  /// Runs `verifyMountedShare` and waits for it, then for the main-queue
  /// updates it queued. Returns how many remounts it asked for.
  private func verify(
    _ share: NetworkShare, on manager: KeepAliveManager,
    probe: @escaping @Sendable (String) -> FileSystemUsage.ProbeOutcome,
    remountSucceeds: Bool = true
  ) -> Int {
    var remounts = 0
    let done = expectation(description: "verified")
    manager.verifyMountedShare(
      share, mountPoint: "/fake/\(share.name)", probe: probe,
      remount: { _, completion in
        remounts += 1
        completion(remountSucceeds)
      },
      completion: { done.fulfill() })
    wait(for: [done], timeout: 2)
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
    return remounts
  }

  func testStaleShareIsUnmountedAndMountedAgain() {
    let manager = makeManager()
    let share = makeShare()

    let remounts = verify(share, on: manager, probe: { _ in .failed(errno: ESTALE) })

    XCTAssertEqual(remounts, 1)
    XCTAssertEqual(manager.staleMountsDetected, 1)
    XCTAssertEqual(manager.retryAttempt(forShareID: share.id), 0, "reconnected")
    XCTAssertFalse(manager.reconnectingShareIDs.contains(share.id))
  }

  func testFailedReconnectCountsAsAnAttemptAndWaitsForItsBackoff() {
    let manager = makeManager()
    let share = makeShare()
    defer { manager.reconcileTargets(validShareIDs: [], validVolumeIDs: []) }

    XCTAssertEqual(
      verify(share, on: manager, probe: { _ in .timedOut }, remountSucceeds: false), 1)
    XCTAssertEqual(manager.retryAttempt(forShareID: share.id), 1)
    XCTAssertTrue(manager.reconnectingShareIDs.contains(share.id))

    // Still stale on the next sweep, but its backoff has not elapsed: no
    // second force unmount, nothing recorded.
    XCTAssertEqual(verify(share, on: manager, probe: { _ in .timedOut }), 0)
    XCTAssertEqual(manager.retryAttempt(forShareID: share.id), 1)
    XCTAssertEqual(manager.staleMountsDetected, 1)
  }

  func testRespondingShareIsLeftAlone() {
    let manager = makeManager()
    let share = makeShare()

    XCTAssertEqual(verify(share, on: manager, probe: { _ in .responding }), 0)
    XCTAssertEqual(verify(share, on: manager, probe: { _ in .failed(errno: EACCES) }), 0)
    XCTAssertEqual(manager.staleMountsDetected, 0)
    XCTAssertEqual(manager.retryAttempt(forShareID: share.id), 0)
    XCTAssertFalse(manager.reconnectingShareIDs.contains(share.id))
  }

  func testSuppressedShareIsNotRemounted() {
    let manager = makeManager()
    let share = makeShare()
    manager.suppress(shareID: share.id)

    XCTAssertEqual(verify(share, on: manager, probe: { _ in .timedOut }), 0)
    XCTAssertEqual(manager.staleMountsDetected, 0)
  }

  func testHungShareTimesOutWithoutHangingTheSweep() {
    let manager = makeManager()
    let share = makeShare()
    let gate = DispatchSemaphore(value: 0)
    // Releases the blocked probe thread, also when an assertion fails.
    addTeardownBlock { gate.signal() }

    let started = Date()
    let remounts = verify(
      share, on: manager,
      probe: { path in
        FileSystemUsage.probe(
          atPath: path, timeout: 0.3,
          statfsCall: { _ in
            gate.wait()
            return 0
          })
      })

    XCTAssertEqual(remounts, 1)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
  }

  func testLowPowerModeDoublesTheSweepTimer() {
    let normal = makeManager(lowPowerMode: false)
    XCTAssertEqual(normal.sweepTimerInterval, normal.retryInterval)
    XCTAssertEqual(normal.sweepTimerIntervalInUse, normal.retryInterval)

    let saving = makeManager(lowPowerMode: true)
    XCTAssertEqual(saving.sweepTimerInterval, saving.retryInterval * 2)
    XCTAssertEqual(saving.sweepTimerIntervalInUse, saving.retryInterval * 2)
  }
}
