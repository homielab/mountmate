//  Created by homielab.com

import XCTest

@testable import MountMate

final class PrivilegedShellTests: XCTestCase {
  private func result(stderr: String = "", exit: Int32? = 0) -> ProcessResult {
    ProcessResult(stdout: "", stderr: stderr, exitCode: exit, timedOut: false)
  }

  // MARK: isWrongPassword

  func testRecognizesSudoWrongPasswordMessages() {
    XCTAssertTrue(
      PrivilegedShell.isWrongPassword(result(stderr: "Sorry, try again.", exit: 1)))
    XCTAssertTrue(
      PrivilegedShell.isWrongPassword(
        result(stderr: "sudo: 1 incorrect password attempt", exit: 1)))
  }

  func testOtherFailuresAreNotWrongPassword() {
    XCTAssertFalse(PrivilegedShell.isWrongPassword(result(stderr: "mount: busy", exit: 1)))
    XCTAssertFalse(PrivilegedShell.isWrongPassword(result()))
  }

  // MARK: run

  func testOsascriptPathWrapsCommandAndNeverAsksForPassword() {
    var calls: [(String, [String], Data?, TimeInterval)] = []
    let outcome = PrivilegedShell.run(
      "echo hi", prompt: "Why", usesSudo: false,
      runner: {
        calls.append(($0, $1, $2, $3))
        return self.result()
      },
      askPassword: { _, _ in
        XCTFail("osascript shows its own prompt")
        return nil
      })
    XCTAssertTrue(outcome.succeeded)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].0, "/usr/bin/osascript")
    XCTAssertEqual(calls[0].1.first, "-e")
    XCTAssertTrue(calls[0].1[1].contains("with administrator privileges"))
    XCTAssertTrue(calls[0].1[1].contains("echo hi"))
    XCTAssertNil(calls[0].2)
  }

  func testSudoPathPassesPasswordOnStdinOnly() {
    var calls: [(String, [String], Data?, TimeInterval)] = []
    let outcome = PrivilegedShell.run(
      "touch /etc/fstab", prompt: "Why", usesSudo: true,
      runner: {
        calls.append(($0, $1, $2, $3))
        return self.result()
      },
      askPassword: { _, _ in "hunter2" })
    XCTAssertTrue(outcome.succeeded)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].0, "/usr/bin/sudo")
    XCTAssertEqual(
      calls[0].1, ["-S", "-k", "-p", "", "/bin/sh", "-c", "touch /etc/fstab"])
    XCTAssertEqual(calls[0].2, Data("hunter2\n".utf8))
    XCTAssertFalse(calls[0].1.joined().contains("hunter2"))
  }

  func testCancellingThePromptReturnsTheCancelMarkerWithoutRunning() {
    let outcome = PrivilegedShell.run(
      "x", prompt: "Why", usesSudo: true,
      runner: { _, _, _, _ in
        XCTFail("nothing may run")
        return self.result()
      },
      askPassword: { _, _ in nil })
    XCTAssertFalse(outcome.succeeded)
    XCTAssertEqual(outcome.stderr, PrivilegedShell.cancelledMarker)
  }

  func testWrongPasswordAsksAgainAndMarksTheRetry() {
    var retries: [Bool] = []
    var runs = 0
    let outcome = PrivilegedShell.run(
      "x", prompt: "Why", usesSudo: true,
      runner: { _, _, _, _ in
        runs += 1
        return runs == 1 ? self.result(stderr: "Sorry, try again.", exit: 1) : self.result()
      },
      askPassword: { _, retry in
        retries.append(retry)
        return "pw"
      })
    XCTAssertTrue(outcome.succeeded)
    XCTAssertEqual(retries, [false, true])
  }

  func testThreeWrongPasswordsGiveUp() {
    var asked = 0
    let outcome = PrivilegedShell.run(
      "x", prompt: "Why", usesSudo: true,
      runner: { _, _, _, _ in self.result(stderr: "Sorry, try again.", exit: 1) },
      askPassword: { _, _ in
        asked += 1
        return "pw"
      })
    XCTAssertEqual(asked, 3)
    XCTAssertFalse(outcome.succeeded)
    XCTAssertFalse(outcome.stderr.isEmpty)
  }

  func testOtherSudoFailureIsReturnedWithoutAskingAgain() {
    var asked = 0
    let failure = result(stderr: "fstab: read-only", exit: 2)
    let outcome = PrivilegedShell.run(
      "x", prompt: "Why", usesSudo: true,
      runner: { _, _, _, _ in failure },
      askPassword: { _, _ in
        asked += 1
        return "pw"
      })
    XCTAssertEqual(asked, 1)
    XCTAssertEqual(outcome, failure)
  }
}
