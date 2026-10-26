//  Created by homielab.com

import XCTest

@testable import MountMate

final class ForceEjectOutcomeTests: XCTestCase {
  private let ok = ProcessResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
  private let unmountError = ProcessResult(
    stdout: "", stderr: "Unmount failed for disk4", exitCode: 1, timedOut: false)
  private let ejectError = ProcessResult(
    stdout: "", stderr: "Eject failed", exitCode: 1, timedOut: false)
  private let timeout = ProcessResult(stdout: "", stderr: "", exitCode: nil, timedOut: true)

  func testFailedUnmountReportsUnmountErrorEvenWhenEjectAlsoFailed() {
    XCTAssertEqual(
      ForceEjectOutcome.choose(unmountResult: unmountError, ejectResult: ejectError),
      .unmountFailed(unmountError))
  }

  func testFailedUnmountWithoutEjectReportsUnmountError() {
    XCTAssertEqual(
      ForceEjectOutcome.choose(unmountResult: unmountError, ejectResult: nil),
      .unmountFailed(unmountError))
  }

  func testUnmountTimeoutIsAnUnmountFailure() {
    XCTAssertEqual(
      ForceEjectOutcome.choose(unmountResult: timeout, ejectResult: nil), .unmountFailed(timeout))
  }

  func testSuccessfulUnmountAndEjectSucceeds() {
    XCTAssertEqual(ForceEjectOutcome.choose(unmountResult: ok, ejectResult: ok), .succeeded)
  }

  func testRAIDSetOnlyUnmountsAndSucceeds() {
    XCTAssertEqual(ForceEjectOutcome.choose(unmountResult: ok, ejectResult: nil), .succeeded)
  }

  func testFailedEjectAfterUnmountReportsEjectError() {
    XCTAssertEqual(
      ForceEjectOutcome.choose(unmountResult: ok, ejectResult: ejectError),
      .ejectFailed(ejectError))
  }

  func testEjectRunsOnlyAfterSuccessfulUnmount() {
    XCTAssertTrue(ForceEjectOutcome.shouldEject(afterUnmount: ok))
    XCTAssertFalse(ForceEjectOutcome.shouldEject(afterUnmount: unmountError))
    XCTAssertFalse(ForceEjectOutcome.shouldEject(afterUnmount: timeout))
  }
}
