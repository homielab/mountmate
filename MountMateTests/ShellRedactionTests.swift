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
}
