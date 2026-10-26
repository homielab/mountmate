import XCTest

@testable import MountMate

final class DiskUtilErrorClassifierTests: XCTestCase {
  private func result(
    stdout: String = "", stderr: String = "", exitCode: Int32? = 1, timedOut: Bool = false
  ) -> ProcessResult {
    ProcessResult(stdout: stdout, stderr: stderr, exitCode: exitCode, timedOut: timedOut)
  }

  // MARK: classify

  func testClassifyTable() {
    let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    let cases: [(String, String, DiskOperation, DiskUtilError)] = [
      (
        "Volume Backup on disk4s2 failed to unmount: dissented by PID 412 (\(finder))",
        "Backup", .unmount, .inUse(process: "Finder")
      ),
      (
        "Volume Backup on disk4s2 failed to unmount: dissented by PID 412 (\(finder))",
        "Backup", .eject, .inUse(process: "Finder")
      ),
      (
        "Volume Backup on disk4s2 failed to mount: resource busy",
        "Backup", .mount, .inUse(process: nil)
      ),
      (
        "Unmount of Backup failed: Resource busy (/usr/libexec/mds)",
        "Backup", .unmount, .inUse(process: "mds")
      ),
      (
        "Volume is in use by another application",
        "Backup", .eject, .inUse(process: nil)
      ),
      (
        "Unmount failed for /dev/disk4: at least one volume could not be unmounted",
        "Disk", .eject, .unmountBusyVolume
      ),
      (
        "Disk Eject: At least one volume could not be unmounted",
        "Disk", .unmount, .unmountBusyVolume
      ),
      (
        "Error: -69854: This is an encrypted and locked APFS Volume; use \"diskutil apfs unlockVolume\"",
        "Secret", .mount, .mountLockedVolume
      ),
      ("Some error", "EFI", .mount, .mountEFIVolume),
      ("Some error", "efi", .mount, .mountEFIVolume),
      ("Some error", "EFI", .unmount, .other),
      ("Could not find disk: disk99", "Backup", .mount, .other),
      ("Operation not permitted", "Backup", .eject, .other),
      ("", "Backup", .mount, .other),
    ]
    for (raw, name, operation, expected) in cases {
      XCTAssertEqual(
        DiskUtilErrorClassifier.classify(raw, for: name, operation: operation), expected,
        "\(operation) \(name): \(raw)")
    }
  }

  func testBusyWinsOverLockedMessage() {
    let raw =
      "busy; This is an encrypted and locked APFS Volume; use \"diskutil apfs unlockVolume\""
    XCTAssertEqual(
      DiskUtilErrorClassifier.classify(raw, for: "X", operation: .mount), .inUse(process: nil))
  }

  func testBlockingProcessName() {
    XCTAssertEqual(
      DiskUtilErrorClassifier.blockingProcessName(in: "dissented by PID 9 (/usr/bin/foo bar)"),
      "foo bar")
    XCTAssertNil(DiskUtilErrorClassifier.blockingProcessName(in: "dissented by PID 9"))
  }

  // MARK: wrong passphrase

  func testWrongPassphraseTable() {
    let cases: [(ProcessResult, Bool)] = [
      (result(stderr: "Error: -69749: The passphrase is incorrect"), true),
      (result(stdout: "Error -69808"), true),
      (result(stderr: "Error: Incorrect Passphrase"), true),
      (result(stderr: "The password you entered is not valid"), true),
      (result(stderr: "Wrong password"), true),
      (result(stderr: "Resource busy"), false),
      (result(stderr: "Incorrect"), false),
      (result(stderr: "Error: -69749", exitCode: nil, timedOut: true), false),
    ]
    for (value, expected) in cases {
      XCTAssertEqual(DiskUtilErrorClassifier.isWrongPassphrase(value), expected, value.stderr)
    }
  }

  // MARK: failureMessage

  func testFailureMessageUsesStderr() {
    XCTAssertEqual(
      DiskUtilErrorClassifier.failureMessage(for: result(stderr: "boom"), timeout: 30), "boom")
  }

  func testFailureMessageFallbacks() {
    XCTAssertTrue(
      DiskUtilErrorClassifier.failureMessage(
        for: result(exitCode: nil, timedOut: true), timeout: 30
      ).contains("30"))
    XCTAssertTrue(
      DiskUtilErrorClassifier.failureMessage(for: result(exitCode: 7), timeout: 30).contains("7"))
  }

  // MARK: presentation

  func testLockedVolumeHasNoAlertText() {
    XCTAssertNil(
      DiskUtilErrorClassifier.presentation(
        for: .mountLockedVolume, name: "X", operation: .mount, details: "d"))
  }

  func testInUsePresentationNamesProcessAndKeepsDetails() throws {
    let text = try XCTUnwrap(
      DiskUtilErrorClassifier.presentation(
        for: .inUse(process: "Finder"), name: "Backup", operation: .unmount, details: "raw out"))
    XCTAssertTrue(text.message.contains("Backup"))
    XCTAssertTrue(text.message.contains("Finder"))
    XCTAssertTrue(text.message.hasSuffix(":\nraw out"))
    let noProcess = try XCTUnwrap(
      DiskUtilErrorClassifier.presentation(
        for: .inUse(process: nil), name: "Backup", operation: .eject, details: "raw out"))
    XCTAssertFalse(noProcess.message.contains("Finder"))
  }

  func testOtherPresentationDiffersPerOperation() throws {
    var titles = Set<String>()
    var messages = Set<String>()
    for operation in [DiskOperation.mount, .unmount, .eject] {
      let text = try XCTUnwrap(
        DiskUtilErrorClassifier.presentation(
          for: .other, name: "Backup", operation: operation, details: "x"))
      titles.insert(text.title)
      messages.insert(text.message)
      XCTAssertTrue(text.message.contains("Backup"))
    }
    XCTAssertEqual(titles.count, 3)
    XCTAssertEqual(messages.count, 3)
  }

  // MARK: locked volume matcher (one source for Mount All and the alert path)

  func testLockedMatcherAndClassifyAgree() {
    let samples = [
      "This is an encrypted and locked APFS Volume; use \"diskutil apfs unlockVolume\"",
      "Volume is encrypted and locked, run diskutil apfs unlockVolume first",
      "use diskutil apfs unlockVolume disk5s1",
    ]
    for sample in samples {
      XCTAssertTrue(
        DiskUtilErrorClassifier.isLockedVolumeFailure(result(stderr: sample)), sample)
      XCTAssertEqual(
        DiskUtilErrorClassifier.classify(sample, for: "Vault", operation: .mount),
        .mountLockedVolume, sample)
    }
  }

  func testLockedMatcherReadsStdoutAndIgnoresTimeouts() {
    XCTAssertTrue(
      DiskUtilErrorClassifier.isLockedVolumeFailure(
        result(stdout: "encrypted and locked", stderr: "")))
    XCTAssertFalse(
      DiskUtilErrorClassifier.isLockedVolumeFailure(
        result(stderr: "encrypted and locked", exitCode: nil, timedOut: true)))
    XCTAssertFalse(
      DiskUtilErrorClassifier.isLockedVolumeFailure(result(stderr: "resource busy")))
  }

  // MARK: busy matcher

  func testBusyMatcherAgreesWithClassify() {
    let samples = [
      "Volume Backup on disk4s2 failed to unmount: resource busy",
      "dissented by PID 12 (/usr/bin/foo)",
      "Resource in use",
      "at least one volume could not be unmounted",
      "Volume failed to mount: unsupported",
      "",
    ]
    for sample in samples {
      let kind = DiskUtilErrorClassifier.classify(sample, for: "X", operation: .eject)
      let isBusyKind: Bool
      switch kind {
      case .inUse, .unmountBusyVolume: isBusyKind = true
      default: isBusyKind = false
      }
      XCTAssertEqual(DiskUtilErrorClassifier.isBusyFailure(stderr: sample), isBusyKind, sample)
    }
  }

  // MARK: remount after a failed unmount

  func testShouldRemountDecision() {
    XCTAssertTrue(
      NetworkMountManager.shouldRemount(afterUnmountSucceeded: true, stillMounted: false))
    XCTAssertTrue(
      NetworkMountManager.shouldRemount(afterUnmountSucceeded: true, stillMounted: true))
    XCTAssertTrue(
      NetworkMountManager.shouldRemount(afterUnmountSucceeded: false, stillMounted: false))
    XCTAssertFalse(
      NetworkMountManager.shouldRemount(afterUnmountSucceeded: false, stillMounted: true))
  }
}
