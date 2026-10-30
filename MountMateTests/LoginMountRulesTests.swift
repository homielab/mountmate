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
      })

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
}
