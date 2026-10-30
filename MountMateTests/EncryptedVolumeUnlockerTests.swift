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

  func testThirdWrongTypedPasswordGivesUp() {
    let result = failure(stderr: "Error: -69749: The passphrase is incorrect")
    XCTAssertEqual(
      UnlockRetryDecision.decide(result: result, isSavedPassword: false, typedFailures: 2),
      .askAgain(passwordFailed: true, logSavedPasswordFailure: false))
    XCTAssertEqual(
      UnlockRetryDecision.decide(result: result, isSavedPassword: false, typedFailures: 3),
      .giveUp)
  }

  func testRejectedSavedPasswordNeverGivesUp() {
    let result = failure(stderr: "Error: -69749: The passphrase is incorrect")
    XCTAssertEqual(
      UnlockRetryDecision.decide(result: result, isSavedPassword: true, typedFailures: 5),
      .askAgain(passwordFailed: true, logSavedPasswordFailure: false))
  }

  func testTimeoutAfterManyTypedFailuresIsReportedNotGivenUp() {
    let result = failure(stderr: "", timedOut: true)
    XCTAssertEqual(
      UnlockRetryDecision.decide(result: result, isSavedPassword: false, typedFailures: 3),
      .reportError)
  }

  // MARK: - Silent unlock (Keep Alive, Wake, Mount All)

  func testSilentUnlockTriesOnlyALockedVolumeWithAFreshSavedPassword() {
    XCTAssertTrue(
      SilentUnlockRules.shouldTrySavedPassword(
        mountFailedLocked: true, hasSavedPassword: true, savedPasswordRejected: false))
    XCTAssertFalse(
      SilentUnlockRules.shouldTrySavedPassword(
        mountFailedLocked: true, hasSavedPassword: false, savedPasswordRejected: false))
    XCTAssertFalse(
      SilentUnlockRules.shouldTrySavedPassword(
        mountFailedLocked: true, hasSavedPassword: true, savedPasswordRejected: true))
    XCTAssertFalse(
      SilentUnlockRules.shouldTrySavedPassword(
        mountFailedLocked: false, hasSavedPassword: true, savedPasswordRejected: false))
  }

  private let lockedMount = ProcessResult(
    stdout: "", stderr: "Volume on disk5s1 failed to mount; it is encrypted and locked",
    exitCode: 1, timedOut: false)

  private let volume = Volume(
    id: "disk5s1", deviceIdentifier: "disk5s1", diskUUID: nil, name: "Vault",
    isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
    usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
    isProtected: false, snapshots: [], storageError: nil)

  private func silentUnlock(
    _ unlocker: EncryptedVolumeUnlocker, hasSavedPassword: Bool = true, volume: Volume? = nil
  ) -> Bool {
    let done = expectation(description: "silent unlock")
    var unlocked = false
    unlocker.unlockSilently(
      volume ?? self.volume, afterMount: lockedMount, hasSavedPassword: hasSavedPassword,
      approvesMount: false
    ) {
      unlocked = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return unlocked
  }

  func testRejectedSavedPasswordIsNotRetriedByTheNextSweep() {
    let host = FakeUnlockHost(result: failure(stderr: "Error: -69749: The passphrase is incorrect"))
    let store = FakeUnlockStore(passwords: ["disk5s1": "secret"])
    let unlocker = EncryptedVolumeUnlocker(host: host, store: store)

    XCTAssertFalse(silentUnlock(unlocker))
    XCTAssertFalse(silentUnlock(unlocker))
    XCTAssertEqual(host.unlockCalls, 1)
    XCTAssertTrue(host.alerts.isEmpty)
  }

  func testSilentUnlockSucceedsWithTheSavedPasswordWithoutAlerts() {
    let host = FakeUnlockHost(
      result: ProcessResult(stdout: "Unlocked", stderr: "", exitCode: 0, timedOut: false))
    let unlocker = EncryptedVolumeUnlocker(
      host: host, store: FakeUnlockStore(passwords: ["disk5s1": "secret"]))

    XCTAssertTrue(silentUnlock(unlocker))
    XCTAssertEqual(host.unlockCalls, 1)
    XCTAssertTrue(host.alerts.isEmpty)
  }

  func testUnlockTargetsTheDeviceOfASameUUIDVolume() {
    let host = FakeUnlockHost(
      result: ProcessResult(stdout: "Unlocked", stderr: "", exitCode: 0, timedOut: false))
    let cloneID = "12345678-1234-1234-1234-123456789ABC#disk6s1"
    let unlocker = EncryptedVolumeUnlocker(
      host: host, store: FakeUnlockStore(passwords: [cloneID: "secret"]))
    let clone = Volume(
      id: cloneID, deviceIdentifier: "disk6s1", diskUUID: nil, name: "Vault",
      isMounted: false, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)

    XCTAssertTrue(silentUnlock(unlocker, volume: clone))
    XCTAssertEqual(
      host.unlockArguments, [["apfs", "unlockVolume", "disk6s1", "-stdinpassphrase"]])
  }

  func testSilentUnlockWithoutSavedPasswordRunsNothing() {
    let host = FakeUnlockHost(result: failure(stderr: ""))
    let unlocker = EncryptedVolumeUnlocker(host: host, store: FakeUnlockStore(passwords: [:]))

    XCTAssertFalse(silentUnlock(unlocker, hasSavedPassword: false))
    XCTAssertEqual(host.unlockCalls, 0)
  }

  func testSilentUnlockTimeoutIsTriedAgainNextTime() {
    let host = FakeUnlockHost(result: failure(stderr: "", timedOut: true))
    let unlocker = EncryptedVolumeUnlocker(
      host: host, store: FakeUnlockStore(passwords: ["disk5s1": "secret"]))

    XCTAssertFalse(silentUnlock(unlocker))
    XCTAssertFalse(silentUnlock(unlocker))
    XCTAssertEqual(host.unlockCalls, 2)
  }
}

private final class FakeUnlockHost: EncryptedVolumeUnlockerHost, @unchecked Sendable {
  private let lock = NSLock()
  private let result: ProcessResult
  private var calls = 0
  private var unlockArgs: [[String]] = []
  var unlockArguments: [[String]] { lock.withLock { unlockArgs } }
  var alerts: [AppAlert] = []

  init(result: ProcessResult) { self.result = result }

  var unlockCalls: Int { lock.withLock { calls } }

  func runDiskUtil(arguments: [String], input: Data) -> ProcessResult {
    if arguments.starts(with: ["apfs", "unlockVolume"]) {
      lock.withLock {
        calls += 1
        unlockArgs.append(arguments)
      }
    }
    return result
  }
  func setBusy(_ volumeID: String, _ busy: Bool) {}
  func refreshDrives(qos: DispatchQoS.QoSClass, then completion: (() -> Void)?) { completion?() }
  func showAlert(_ alert: AppAlert) { alerts.append(alert) }
  func reportUnlockFailure(_ result: ProcessResult, for volume: Volume) {}
  func updateSavedPasswordIDs(_ change: SavedPasswordChange) {}
}

private final class FakeUnlockStore: UnlockPasswordStore, @unchecked Sendable {
  private let passwords: [String: String]
  init(passwords: [String: String]) { self.passwords = passwords }
  func load(account: String) -> String? { passwords[account] }
  func savedAccounts() -> Set<String> { Set(passwords.keys) }
  func save(password: String, for account: String, name: String, kind: KeychainItemKind)
    -> OSStatus
  { errSecSuccess }
  func delete(account: String) -> OSStatus { errSecSuccess }
  func updateLabel(for account: String, name: String, kind: KeychainItemKind) -> OSStatus {
    errSecSuccess
  }
}
