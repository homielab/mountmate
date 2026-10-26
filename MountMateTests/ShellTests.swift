//  Created by homielab.com

import XCTest

@testable import MountMate

final class ShellTests: XCTestCase {
  func testSuccessfulProcessReturnsTrimmedOutputAndExitCode() {
    let result = runProcess(executable: "/bin/echo", arguments: ["hello"])
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.stdout, "hello")
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.timedOut)
  }

  func testNonZeroExitIsAFailureWithItsCode() {
    let result = runProcess(executable: "/usr/bin/false", arguments: [])
    XCTAssertFalse(result.succeeded)
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertFalse(result.timedOut)
  }

  func testTimeoutReportsTimedOutAndKillsTheProcess() {
    let started = Date()
    let result = runProcess(executable: "/bin/sleep", arguments: ["5"], timeout: 1)
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertTrue(result.timedOut)
    XCTAssertNil(result.exitCode)
    XCTAssertFalse(result.succeeded)
    // 1 s timeout + the SIGTERM grace period (2 s) at most; far below the 5 s sleep.
    XCTAssertGreaterThanOrEqual(elapsed, 0.9)
    XCTAssertLessThan(elapsed, 4.5)
  }

  func testTimedOutProcessIsGoneAfterwards() throws {
    // Marker argument so only this test's sleeper is matched.
    let marker = "7\(Int.random(in: 100_000...999_999))"
    _ = runProcess(executable: "/bin/sleep", arguments: [marker], timeout: 1)
    let deadline = Date().addingTimeInterval(3)
    var found = true
    while found && Date() < deadline {
      let probe = runProcess(executable: "/usr/bin/pgrep", arguments: ["-f", "sleep \(marker)"])
      found = probe.succeeded
      if found { Thread.sleep(forTimeInterval: 0.1) }
    }
    XCTAssertFalse(found, "the timed-out process was left running")
  }

  func testLargeOutputIsCapturedCompletely() {
    // 2 MB through stdin and back: far more than a pipe buffer holds.
    let payload = Data(repeating: UInt8(ascii: "x"), count: 2_000_000)
    let result = runProcess(
      executable: "/bin/cat", arguments: [], input: payload, timeout: 20)
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.stdout.utf8.count, payload.count)
  }

  func testProcessThatIgnoresItsInputDoesNotHangOrCrash() {
    // `true` exits without reading stdin: the write fails with EPIPE, which
    // must not raise SIGPIPE in the app.
    let payload = Data(repeating: UInt8(ascii: "y"), count: 4_000_000)
    let result = runProcess(
      executable: "/usr/bin/true", arguments: [], input: payload, timeout: 10)
    XCTAssertTrue(result.succeeded)
    XCTAssertFalse(result.timedOut)
  }

  func testProcessWithoutInputSeesEndOfInputImmediately() {
    // `cat` returns at once only if its stdin is closed or empty.
    let started = Date()
    let result = runProcess(executable: "/bin/cat", arguments: [], timeout: 5)
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.stdout, "")
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
  }

  func testMissingExecutableFailsInsteadOfCrashing() {
    let result = runProcess(executable: "/nonexistent/tool", arguments: [])
    XCTAssertFalse(result.succeeded)
  }
}
