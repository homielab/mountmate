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

  func testVerifyFailedCodeCountsAsProblemsAndHidesRawLine() {
    let result = ProcessResult(
      stdout: "Checking file system\nChecking catalog file.",
      stderr: "Error: -69845: File system verify or repair failed\n",
      exitCode: 1,
      timedOut: false
    )
    let outcome = VolumeVerificationRules.outcome(for: result, volumeName: "Data")

    XCTAssertTrue(outcome.message.contains("Problems were found"))
    XCTAssertFalse(outcome.message.contains("-69845"))
  }

  func testNTFSIsNotReportedAsDamaged() {
    let result = ProcessResult(
      stdout: "", stderr: "Error: -69845: File system verify or repair failed",
      exitCode: 1, timedOut: false)
    let outcome = VolumeVerificationRules.outcome(
      for: result, volumeName: "Win", fileSystemType: "ntfs")

    XCTAssertEqual(
      VolumeVerificationRules.failureKind(for: result, fileSystemType: "ntfs"), .unsupported)
    XCTAssertTrue(outcome.message.contains("was not checked"))
    XCTAssertFalse(outcome.message.contains("Problems were found"))
    XCTAssertFalse(outcome.message.contains("First Aid"))
  }

  func testBusyUnmountedPermissionAndUnknownAreNeutral() {
    func kind(_ stderr: String) -> VolumeVerificationRules.FailureKind {
      VolumeVerificationRules.failureKind(
        for: ProcessResult(stdout: "", stderr: stderr, exitCode: 1, timedOut: false))
    }
    XCTAssertEqual(kind("Error: -69877: Couldn't open device (Resource busy)"), .busy)
    XCTAssertEqual(kind("Could not find disk: disk9s2"), .notMounted)
    XCTAssertEqual(kind("Operation not permitted"), .permission)
    XCTAssertEqual(kind("Something odd"), .unknown)
    XCTAssertEqual(kind("Unrecognized file system"), .unsupported)

    let outcome = VolumeVerificationRules.outcome(
      for: ProcessResult(
        stdout: "", stderr: "Error: -69877: Couldn't open device (Resource busy)", exitCode: 1,
        timedOut: false), volumeName: "USB")
    XCTAssertTrue(outcome.message.contains("in use"))
    XCTAssertFalse(outcome.message.contains("Problems were found"))
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
