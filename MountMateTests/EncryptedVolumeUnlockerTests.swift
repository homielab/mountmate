import XCTest

@testable import MountMate

final class EncryptedVolumeUnlockerTests: XCTestCase {
  private func failure(stderr: String, timedOut: Bool = false) -> ProcessResult {
    ProcessResult(stdout: "", stderr: stderr, exitCode: timedOut ? nil : 1, timedOut: timedOut)
  }

  func testWrongTypedPasswordAsksAgainWithRetryWording() {
    let result = failure(stderr: "Error: -69749: The passphrase is incorrect")
    XCTAssertEqual(
      UnlockRetryDecision.decide(result: result, isSavedPassword: false),
      .askAgain(passwordFailed: true, logSavedPasswordFailure: false))
  }

  func testRejectedSavedPasswordAsksAgainWithoutLogging() {
    let result = failure(stderr: "Error: -69808: incorrect passphrase")
    XCTAssertEqual(
      UnlockRetryDecision.decide(result: result, isSavedPassword: true),
      .askAgain(passwordFailed: true, logSavedPasswordFailure: false))
  }

  func testSavedPasswordFailingForAnotherReasonAsksAgainAndLogs() {
    let result = failure(stderr: "Error: something else")
    XCTAssertEqual(
      UnlockRetryDecision.decide(result: result, isSavedPassword: true),
      .askAgain(passwordFailed: false, logSavedPasswordFailure: true))
  }

  func testSavedPasswordTimeoutIsReported() {
    let result = failure(stderr: "", timedOut: true)
    XCTAssertEqual(UnlockRetryDecision.decide(result: result, isSavedPassword: true), .reportError)
  }

  func testOtherFailureOfTypedPasswordIsReported() {
    let result = failure(stderr: "Error: -69854: busy")
    XCTAssertEqual(UnlockRetryDecision.decide(result: result, isSavedPassword: false), .reportError)
  }
}
