//  Created by homielab.com

import XCTest

@testable import MountMate

final class LoginMountRulesTests: XCTestCase {
  private let nas = NetworkShare(
    name: "NAS", server: "nas.local", sharePath: "media", username: "me", mountAtLogin: true,
    keepMounted: false)

  private func due(
    _ shares: [NetworkShare]? = nil,
    network: Bool = true,
    pending: Set<UUID>? = nil,
    mounting: Set<UUID> = [],
    retries: [UUID: Int] = [:],
    mounted: Set<UUID> = [],
    suppressed: Set<UUID> = []
  ) -> [UUID] {
    LoginMountRules.sharesToRetry(
      shares: shares ?? [nas], isNetworkAvailable: network, pendingIDs: pending ?? [nas.id],
      mountingIDs: mounting, retries: retries, isMounted: { mounted.contains($0.id) },
      isSuppressed: { suppressed.contains($0) }
    ).map(\.id)
  }

  // MARK: - Rules

  func testUnmountedLoginShareIsRetriedWhileRetriesAreLeft() {
    XCTAssertEqual(due(), [nas.id])
    XCTAssertEqual(due(retries: [nas.id: LoginMountRules.maxRetries - 1]), [nas.id])
  }

  func testNothingIsRetriedWithoutNetwork() {
    XCTAssertEqual(due(network: false), [])
  }

  func testMountedShareIsNotRetried() {
    XCTAssertEqual(due(mounted: [nas.id]), [])
  }

  func testShareIsNotRetriedOnceRetriesAreUsedUp() {
    XCTAssertEqual(due(retries: [nas.id: LoginMountRules.maxRetries]), [])
  }

  func testShareTheUserUnmountedIsNotRetried() {
    XCTAssertEqual(due(suppressed: [nas.id]), [])
  }

  func testShareBeingMountedOrNotPendingIsNotRetried() {
    XCTAssertEqual(due(mounting: [nas.id]), [])
    XCTAssertEqual(due(pending: []), [])
  }

  func testShareNoLongerMarkedMountAtLoginIsNotRetried() {
    var share = nas
    share.mountAtLogin = false
    XCTAssertEqual(due([share], pending: [share.id]), [])
  }

  func testRetryDelaysGrowThenRepeatTheLastStep() {
    let delays = (1...LoginMountRules.maxRetries).map {
      LoginMountRules.retryDelay(beforeRetry: $0)
    }
    XCTAssertEqual(delays, [15, 30, 60, 120, 120])
    XCTAssertNil(LoginMountRules.retryDelay(beforeRetry: LoginMountRules.maxRetries + 1))
    XCTAssertNil(LoginMountRules.retryDelay(beforeRetry: 0))
  }

  func testTimerWaitsForTheEarliestShareNotBeingMounted() {
    let other = UUID()
    XCTAssertEqual(
      LoginMountRules.nextTimerDelay(
        pendingIDs: [nas.id, other], mountingIDs: [], retries: [nas.id: 2, other: 1]), 30)
    XCTAssertEqual(
      LoginMountRules.nextTimerDelay(
        pendingIDs: [nas.id, other], mountingIDs: [other], retries: [nas.id: 2, other: 1]), 60)
    XCTAssertNil(
      LoginMountRules.nextTimerDelay(pendingIDs: [nas.id], mountingIDs: [nas.id], retries: [:]))
    XCTAssertNil(
      LoginMountRules.nextTimerDelay(
        pendingIDs: [nas.id], mountingIDs: [], retries: [nas.id: LoginMountRules.maxRetries]))
    XCTAssertNil(LoginMountRules.nextTimerDelay(pendingIDs: [], mountingIDs: [], retries: [:]))
  }

  // MARK: - Retrier

  /// A retrier whose mounts are recorded and answered by `results` (in
  /// order; `false` once used up).
  private final class Harness {
    var shares: [NetworkShare]
    var mounted = Set<UUID>()
    var suppressed = Set<UUID>()
    var results: [Bool] = []
    private(set) var mounts: [UUID] = []
    /// Completions not answered yet (`answerLater`).
    private var waiting: [(Bool, String?) -> Void] = []
    var answerLater = false
    /// Delays asked of the scheduler, in order.
    private(set) var scheduledDelays: [TimeInterval] = []
    /// The timer block not fired or cancelled yet.
    private var timer: (() -> Void)?
    var hasTimer: Bool { timer != nil }
    var usesTimer = false
    lazy var retrier = LoginMountRetrier(
      shares: { [unowned self] in self.shares },
      isMounted: { [unowned self] in self.mounted.contains($0.id) },
      isSuppressed: { [unowned self] in self.suppressed.contains($0) },
      mount: { [unowned self] share, completion in
        self.mounts.append(share.id)
        if self.answerLater {
          self.waiting.append(completion)
        } else {
          completion(self.results.isEmpty ? false : self.results.removeFirst(), "offline")
        }
      },
      schedule: usesTimer
        ? { [unowned self] delay, block in
          XCTAssertNil(self.timer, "only one retry timer at a time")
          self.scheduledDelays.append(delay)
          self.timer = block
          return { [unowned self] in self.timer = nil }
        } : nil)

    /// Fires the pending timer, as the main queue would after its delay.
    func fireTimer() {
      guard let block = timer else { return XCTFail("no timer scheduled") }
      timer = nil
      block()
    }

    init(shares: [NetworkShare]) { self.shares = shares }

    func answerWaiting(_ success: Bool) {
      let pending = waiting
      waiting.removeAll()
      for completion in pending { completion(success, nil) }
    }
  }

  func testLaunchMountsOnlyLoginShares() {
    let other = NetworkShare(
      name: "Backup", server: "nas.local", sharePath: "backup", username: "me",
      mountAtLogin: false)
    let harness = Harness(shares: [nas, other])
    harness.retrier.mountAtLaunch()
    XCTAssertEqual(harness.mounts, [nas.id])
    XCTAssertEqual(harness.retrier.pendingIDs, [nas.id])
  }

  func testFailedLaunchMountIsRetriedAtMostFiveTimes() {
    let harness = Harness(shares: [nas])
    harness.retrier.mountAtLaunch()
    for _ in 0..<(LoginMountRules.maxRetries + 3) {
      harness.retrier.retry()
    }
    XCTAssertEqual(harness.mounts.count, 1 + LoginMountRules.maxRetries)
    XCTAssertFalse(harness.retrier.hasPendingShares)
  }

  func testRetryStopsOnceTheShareMounts() {
    let harness = Harness(shares: [nas])
    harness.results = [false, true]
    harness.retrier.mountAtLaunch()
    XCTAssertEqual(harness.retrier.retry().map(\.id), [nas.id])
    XCTAssertTrue(harness.retrier.pendingIDs.isEmpty)
    XCTAssertEqual(harness.retrier.retry(), [])
    XCTAssertEqual(harness.mounts.count, 2)
  }

  func testSuccessfulLaunchMountIsNeverRetried() {
    let harness = Harness(shares: [nas])
    harness.results = [true]
    harness.retrier.mountAtLaunch()
    XCTAssertFalse(harness.retrier.hasPendingShares)
    XCTAssertEqual(harness.retrier.retry(), [])
  }

  func testNoRetryWhileTheLaunchMountIsStillRunning() {
    let harness = Harness(shares: [nas])
    harness.answerLater = true
    harness.retrier.mountAtLaunch()
    XCTAssertEqual(harness.retrier.retry(), [])
    harness.answerWaiting(false)
    XCTAssertEqual(harness.retrier.retry().map(\.id), [nas.id])
  }

  func testShareMountedOrUnmountedByTheUserMeanwhileIsLeftAlone() {
    let harness = Harness(shares: [nas])
    harness.retrier.mountAtLaunch()
    harness.suppressed = [nas.id]
    XCTAssertEqual(harness.retrier.retry(), [])
    harness.suppressed = []
    harness.mounted = [nas.id]
    XCTAssertEqual(harness.retrier.retry(), [])
    XCTAssertEqual(harness.mounts.count, 1)
  }

  // MARK: - Timer

  private func timedHarness(_ shares: [NetworkShare]? = nil) -> Harness {
    let harness = Harness(shares: shares ?? [nas])
    harness.usesTimer = true
    return harness
  }

  func testFailedLaunchMountIsRetriedOnTheTimerWithoutNetworkChanges() {
    let harness = timedHarness()
    harness.retrier.mountAtLaunch()
    XCTAssertEqual(harness.scheduledDelays, [15])
    for _ in 0..<LoginMountRules.maxRetries {
      harness.fireTimer()
    }
    XCTAssertEqual(harness.mounts.count, 1 + LoginMountRules.maxRetries)
    XCTAssertEqual(harness.scheduledDelays, [15, 30, 60, 120, 120])
    XCTAssertFalse(harness.hasTimer)
    XCTAssertFalse(harness.retrier.isTimerScheduled)
    XCTAssertFalse(harness.retrier.hasPendingShares)
  }

  func testTimerStopsOnceTheShareMounts() {
    let harness = timedHarness()
    harness.results = [false, false, true]
    harness.retrier.mountAtLaunch()
    harness.fireTimer()
    harness.fireTimer()
    XCTAssertEqual(harness.mounts.count, 3)
    XCTAssertEqual(harness.scheduledDelays, [15, 30])
    XCTAssertFalse(harness.hasTimer)
    XCTAssertFalse(harness.retrier.isTimerScheduled)
  }

  func testSuccessfulLaunchMountSchedulesNoTimer() {
    let harness = timedHarness()
    harness.results = [true]
    harness.retrier.mountAtLaunch()
    XCTAssertEqual(harness.scheduledDelays, [])
    XCTAssertFalse(harness.retrier.isTimerScheduled)
  }

  func testTimerDoesNothingForAShareTheUserUnmountedOrMountedMeanwhile() {
    let harness = timedHarness()
    harness.retrier.mountAtLaunch()
    harness.suppressed = [nas.id]
    harness.fireTimer()
    XCTAssertEqual(harness.mounts.count, 1)
    XCTAssertFalse(harness.hasTimer)

    let mountedMeanwhile = timedHarness()
    mountedMeanwhile.retrier.mountAtLaunch()
    mountedMeanwhile.mounted = [nas.id]
    mountedMeanwhile.fireTimer()
    XCTAssertEqual(mountedMeanwhile.mounts.count, 1)
    XCTAssertFalse(mountedMeanwhile.hasTimer)
  }

  func testTimerSkipsAShareStillBeingMountedAndWaitsForItsResult() {
    let harness = timedHarness()
    harness.retrier.mountAtLaunch()
    // A network change starts retry 1 before the timer fires.
    harness.answerLater = true
    XCTAssertEqual(harness.retrier.retry().map(\.id), [nas.id])
    harness.fireTimer()
    XCTAssertEqual(harness.mounts.count, 2)
    XCTAssertFalse(harness.hasTimer)
    harness.answerWaiting(false)
    XCTAssertEqual(harness.scheduledDelays, [15, 30])
    XCTAssertTrue(harness.hasTimer)
  }

  func testNetworkAndTimerRetriesShareTheBudget() {
    let harness = timedHarness()
    harness.retrier.mountAtLaunch()
    harness.retrier.retry()
    harness.retrier.retry()
    harness.fireTimer()
    harness.retrier.retry()
    harness.fireTimer()
    XCTAssertEqual(harness.mounts.count, 1 + LoginMountRules.maxRetries)
    XCTAssertEqual(harness.retrier.retries[nas.id], LoginMountRules.maxRetries)
    XCTAssertFalse(harness.hasTimer)
    XCTAssertEqual(harness.retrier.retry(), [])
  }

  func testTimerRunsTheRetryActionGivenInsteadOfRetryingDirectly() {
    var fired = 0
    var block: (() -> Void)?
    let retrier = LoginMountRetrier(
      shares: { [nas] in [nas] }, isMounted: { _ in false }, isSuppressed: { _ in false },
      mount: { _, completion in completion(false, nil) },
      schedule: { _, run in
        block = run
        return {}
      },
      retryWhenDue: { fired += 1 })
    retrier.mountAtLaunch()
    block?()
    XCTAssertEqual(fired, 1)
    XCTAssertEqual(retrier.retries, [:])
    XCTAssertFalse(retrier.isTimerScheduled)
  }
}
