//  Created by homielab.com

import XCTest

@testable import MountMate

final class FileSystemUsageTests: XCTestCase {
  func testReadsTotalAndFreeSpaceOfTheRoot() {
    guard case .usage(let total, let free) = FileSystemUsage.read(atPath: "/") else {
      return XCTFail("expected usage for /")
    }
    XCTAssertGreaterThan(total, 0)
    XCTAssertGreaterThanOrEqual(free, 0)
    XCTAssertLessThanOrEqual(free, total)
  }

  func testMissingPathFails() {
    guard case .failed = FileSystemUsage.read(atPath: "/nonexistent-\(UUID().uuidString)") else {
      return XCTFail("expected .failed")
    }
  }

  func testPathStillBeingReadIsSkippedWithoutBlocking() {
    let path = "/nonexistent-inflight-\(UUID().uuidString)"
    XCTAssertTrue(FileSystemUsage.beginRead(of: path))
    defer { FileSystemUsage.endRead(of: path) }

    let started = Date()
    guard case .timedOut = FileSystemUsage.read(atPath: path, timeout: 5) else {
      return XCTFail("a path with a read in flight must report .timedOut")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
  }

  func testPathIsReadableAgainOnceTheEarlierReadEnds() {
    let path = "/nonexistent-reuse-\(UUID().uuidString)"
    XCTAssertTrue(FileSystemUsage.beginRead(of: path))
    XCTAssertFalse(FileSystemUsage.beginRead(of: path))
    FileSystemUsage.endRead(of: path)
    guard case .failed = FileSystemUsage.read(atPath: path) else {
      return XCTFail("expected a real read after endRead")
    }
  }

  func testFinishedReadLeavesNothingInFlight() {
    let path = "/nonexistent-clean-\(UUID().uuidString)"
    _ = FileSystemUsage.read(atPath: path)
    XCTAssertTrue(FileSystemUsage.beginRead(of: path))
    FileSystemUsage.endRead(of: path)
  }

  // MARK: - Probe

  func testProbeOfTheRootResponds() {
    XCTAssertEqual(FileSystemUsage.probe(atPath: "/", timeout: 2), .responding)
  }

  func testProbeReportsTheErrno() {
    XCTAssertEqual(
      FileSystemUsage.probe(atPath: "/nonexistent-\(UUID().uuidString)", timeout: 2),
      .failed(errno: ENOENT))
    XCTAssertEqual(
      FileSystemUsage.probe(atPath: "/fake-stale", timeout: 2, statfsCall: { _ in ESTALE }),
      .failed(errno: ESTALE))
  }

  func testHungProbeTimesOutAndTheNextOneDoesNotPileUp() {
    let path = "/fake-hung-\(UUID().uuidString)"
    let gate = DispatchSemaphore(value: 0)
    // Releases the blocked thread, also when an assertion fails.
    addTeardownBlock { gate.signal() }
    let hang: @Sendable (String) -> Int32 = { _ in
      gate.wait()
      return 0
    }

    let started = Date()
    XCTAssertEqual(
      FileSystemUsage.probe(atPath: path, timeout: 0.2, statfsCall: hang), .timedOut)
    // The first probe is still blocked: the second one returns at once.
    XCTAssertEqual(
      FileSystemUsage.probe(atPath: path, timeout: 5, statfsCall: hang), .timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
  }

  func testCapacityReadInFlightDoesNotMakeAProbeTimeOut() {
    let path = "/nonexistent-shared-\(UUID().uuidString)"
    XCTAssertTrue(FileSystemUsage.beginRead(of: path))
    defer { FileSystemUsage.endRead(of: path) }
    XCTAssertEqual(
      FileSystemUsage.probe(atPath: path, timeout: 2, statfsCall: { _ in 0 }), .responding)
  }
}
