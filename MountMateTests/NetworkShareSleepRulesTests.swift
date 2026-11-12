import XCTest

@testable import MountMate

final class NetworkShareSleepRulesTests: XCTestCase {
  private func share(_ name: String, keepMounted: Bool = false) -> NetworkShare {
    NetworkShare(
      name: name, server: "nas.local", sharePath: name, username: "u", keepMounted: keepMounted)
  }

  func testOffByDefault() throws {
    let suite = "NetworkShareSleepRulesTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertFalse(NetworkShareSleepRules.isEnabled(defaults: defaults))
  }

  func testOffLeavesSharesUntouched() {
    let a = share("A")
    XCTAssertTrue(
      NetworkShareSleepRules.candidates(isEnabled: false, shares: [a], mountedIDs: [a.id]).isEmpty)
  }

  func testOnTakesMountedSharesWithoutKeepAliveInSavedOrder() {
    let a = share("A")
    let b = share("B")
    let notMounted = share("NotMounted")
    let kept = share("Kept", keepMounted: true)
    let result = NetworkShareSleepRules.candidates(
      isEnabled: true, shares: [a, notMounted, kept, b], mountedIDs: [a.id, b.id, kept.id])
    XCTAssertEqual(result.map(\.name), ["A", "B"])
  }
}
