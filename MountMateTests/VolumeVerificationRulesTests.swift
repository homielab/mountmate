//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeVerificationRulesTests: XCTestCase {
  func testArgumentsOnlyUsesVerifyVolumeAndNeverRepairs() {
    let args = VolumeVerificationRules.arguments(forDevice: "disk5s1")

    XCTAssertEqual(args, ["verifyVolume", "disk5s1"])
    for argument in args {
      XCTAssertFalse(
        argument.localizedCaseInsensitiveContains("repair"),
        "Verification arguments must never run repair: \(argument)")
    }
  }

  func testDefaultTimeoutIsAtLeastSixtySeconds() {
    XCTAssertGreaterThanOrEqual(VolumeVerificationRules.defaultTimeout, 60.0)
  }

  func testSuccessfulVerificationOutcome() {
    let result = ProcessResult(
      stdout: "The volume appeared to be OK.",
      stderr: "",
      exitCode: 0,
      timedOut: false
    )
    let outcome = VolumeVerificationRules.outcome(for: result, volumeName: "Backups")

    XCTAssertTrue(outcome.succeeded)
    XCTAssertEqual(
      outcome.title,
      NSLocalizedString("Volume Verified", comment: "Alert title: volume verification succeeded"))
    XCTAssertTrue(outcome.message.contains("Backups"))
    XCTAssertTrue(outcome.message.contains("No problems were found"))
  }

  func testTimedOutVerificationOutcome() {
    let result = ProcessResult(
      stdout: "",
      stderr: "Process timed out",
      exitCode: nil,
      timedOut: true
    )
    let outcome = VolumeVerificationRules.outcome(for: result, volumeName: "SlowDrive")

    XCTAssertFalse(outcome.succeeded)
    XCTAssertEqual(
      outcome.title,
      NSLocalizedString(
        "Volume Verification Failed",
        comment: "Alert title: volume verification timed out or failed"
      ))
    XCTAssertTrue(outcome.message.contains("SlowDrive"))
    XCTAssertTrue(outcome.message.contains("did not finish in time"))
    XCTAssertTrue(outcome.message.contains("Disk Utility"))
  }

  func testFailedVerificationOutcomeWithCorruptVolume() {
    let result = ProcessResult(
      stdout: "The volume was found corrupt and needs to be repaired.",
      stderr: "File system check exit code is 8",
      exitCode: 8,
      timedOut: false
    )
    let outcome = VolumeVerificationRules.outcome(for: result, volumeName: "CorruptDrive")

    XCTAssertFalse(outcome.succeeded)
    XCTAssertEqual(
      outcome.title,
      NSLocalizedString(
        "Volume Verification Failed",
        comment: "Alert title: volume verification timed out or failed"
      ))
    XCTAssertTrue(outcome.message.contains("CorruptDrive"))
    XCTAssertTrue(outcome.message.contains("Problems were found"))
    XCTAssertTrue(outcome.message.contains("Disk Utility"))
  }

  func testFailedVerificationAppendsDiskutilsLastErrorLine() {
    let result = ProcessResult(
      stdout: "Checking file system\nChecking catalog file.",
      stderr: "Error: -69845: File system verify or repair failed\n",
      exitCode: 1,
      timedOut: false
    )
    let outcome = VolumeVerificationRules.outcome(for: result, volumeName: "Data")

    XCTAssertTrue(
      outcome.message.hasSuffix("\n\nError: -69845: File system verify or repair failed"))
  }

  func testFailureDetailFallsBackToStdoutAndIsNilWhenSilent() {
    XCTAssertEqual(
      VolumeVerificationRules.failureDetail(
        ProcessResult(stdout: "a\n  last line  \n\n", stderr: "", exitCode: 1, timedOut: false)),
      "last line")
    XCTAssertNil(
      VolumeVerificationRules.failureDetail(
        ProcessResult(stdout: "", stderr: " \n", exitCode: 1, timedOut: false)))
  }
}
