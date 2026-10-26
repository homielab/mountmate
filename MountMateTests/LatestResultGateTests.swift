import XCTest

@testable import MountMate

final class LatestResultGateTests: XCTestCase {
  func testOlderResultArrivingLateIsDropped() {
    var gate = LatestResultGate()
    let older = gate.begin()
    let newer = gate.begin()
    XCTAssertTrue(gate.shouldApply(newer))
    XCTAssertFalse(gate.shouldApply(older))
  }

  func testResultsArrivingInOrderAreAllApplied() {
    var gate = LatestResultGate()
    let first = gate.begin()
    let second = gate.begin()
    XCTAssertTrue(gate.shouldApply(first))
    XCTAssertTrue(gate.shouldApply(second))
  }

  func testOlderResultAppliesWhenNewerRunPublishedNothing() {
    // A newer run that fails (e.g. `/sbin/mount` errors) never publishes,
    // so an older successful result is still the latest one.
    var gate = LatestResultGate()
    let older = gate.begin()
    _ = gate.begin()
    XCTAssertTrue(gate.shouldApply(older))
  }

  func testSameTicketIsAppliedOnce() {
    var gate = LatestResultGate()
    let ticket = gate.begin()
    XCTAssertTrue(gate.shouldApply(ticket))
    XCTAssertFalse(gate.shouldApply(ticket))
  }
}
