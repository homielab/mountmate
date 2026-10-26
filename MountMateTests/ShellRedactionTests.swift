import XCTest

@testable import MountMate

final class ShellRedactionTests: XCTestCase {
  func testURLPasswordIsRedacted() {
    XCTAssertEqual(
      redactedArguments(["-o", "noowners,nosuid", "smb://alice:s3cr%40t@nas.local/share", "/Volumes/share"]),
      ["-o", "noowners,nosuid", "smb://alice:***@nas.local/share", "/Volumes/share"])
  }

  func testSchemelessURLPasswordIsRedacted() {
    XCTAssertEqual(
      redactedArguments(["//bob:hunter2@server/share"]), ["//bob:***@server/share"])
  }

  func testAFPURLPasswordIsRedacted() {
    XCTAssertEqual(
      redactedArguments(["afp://carol:pa:ss@host.local/Data"]), ["afp://carol:***@host.local/Data"])
  }

  func testURLWithoutPasswordIsUnchanged() {
    let arguments = ["smb://alice@nas.local/share", "smb://nas.local:445/share", "nfs-server:/export"]
    XCTAssertEqual(redactedArguments(arguments), arguments)
  }

  func testArgumentAfterSecretFlagIsRedacted() {
    XCTAssertEqual(
      redactedArguments(["apfs", "unlockVolume", "disk5s1", "-passphrase", "topsecret"]),
      ["apfs", "unlockVolume", "disk5s1", "-passphrase", "***"])
  }

  func testOrdinaryArgumentsAreUnchanged() {
    let arguments = ["apfs", "unlockVolume", "disk5s1", "-stdinpassphrase"]
    XCTAssertEqual(redactedArguments(arguments), arguments)
  }

  func testErrorTextRedactsBothURLForms() {
    XCTAssertEqual(
      redactingURLPasswords(
        "mount_smbfs: smb://alice:s3cr%40t@nas.local/share: Authentication error"),
      "mount_smbfs: smb://alice:***@nas.local/share: Authentication error")
    XCTAssertEqual(
      redactingURLPasswords("server connection failed: //bob:hunter2@server/share"),
      "server connection failed: //bob:***@server/share")
    XCTAssertEqual(
      redactingURLPasswords("nfs://u:a@b@host/x and //v:c:d@host2/y"),
      "nfs://u:***@host/x and //v:***@host2/y")
  }

  func testErrorTextWithoutPasswordIsUnchanged() {
    for text in [
      "mount_smbfs: server connection failed: No route to host",
      "smb://alice@nas.local/share is busy",
      "smb://nas.local:445/share failed, contact admin@example.com",
      "//server/share on /Volumes/share (smbfs, nodev, nosuid, mounted by bob)",
    ] {
      XCTAssertEqual(redactingURLPasswords(text), text)
    }
  }
}
