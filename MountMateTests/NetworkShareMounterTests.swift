//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkShareMounterTests: XCTestCase {
  private let share = NetworkShare(
    name: "Photos", server: "nas.local", sharePath: "photos", username: "",
    shareProtocol: .smb)

  // MARK: stalled mounts

  func testAutomaticMountAlwaysWaitsForStalledCall() {
    XCTAssertTrue(NetworkShareMounter.shouldBlock(stallAge: 0, userInitiated: false))
    XCTAssertTrue(
      NetworkShareMounter.shouldBlock(
        stallAge: NetworkShareMounter.stalledMountRetryAge * 10, userInitiated: false))
  }

  func testUserMountWaitsUntilStallIsOldEnough() {
    let age = NetworkShareMounter.stalledMountRetryAge
    XCTAssertTrue(NetworkShareMounter.shouldBlock(stallAge: age - 1, userInitiated: true))
    XCTAssertFalse(NetworkShareMounter.shouldBlock(stallAge: age, userInitiated: true))
    XCTAssertFalse(NetworkShareMounter.shouldBlock(stallAge: age + 60, userInitiated: true))
  }

  // MARK: connection URL

  func testConnectionURLPerProtocol() {
    func url(_ proto: ShareProtocol, path: String, user: String? = nil) -> String? {
      let share = NetworkShare(
        name: "s", server: "nas", sharePath: path, username: "", shareProtocol: proto)
      return NetworkShareMounter.connectionURL(for: share, user: user)?.absoluteString
    }
    XCTAssertEqual(url(.smb, path: "photos"), "smb://nas/photos")
    XCTAssertEqual(url(.afp, path: "photos"), "afp://nas/photos")
    XCTAssertEqual(url(.nfs, path: "export/data"), "nfs://nas/export/data")
    XCTAssertEqual(url(.smb, path: "photos", user: "CORP;alice"), "smb://CORP;alice@nas/photos")
  }

  // MARK: mount result to message and clean-up

  private func resolve(
    _ outcome: NetworkShareMounter.MountOutcome, userInitiated: Bool = true,
    isSuppressed: Bool = false
  ) -> MountResolution {
    NetworkShareMounter.resolution(
      for: outcome, share: share, userInitiated: userInitiated, isSuppressed: isSuppressed)
  }

  func testSuccessIsReportedWithoutMessageOrCleanUp() {
    XCTAssertEqual(
      resolve(.success),
      MountResolution(success: true, message: nil, cleanUpMountPoint: false, undoMount: false))
    // Suppression only matters for automatic mounts.
    XCTAssertTrue(resolve(.success, userInitiated: true, isSuppressed: true).success)
    XCTAssertTrue(resolve(.success, userInitiated: false, isSuppressed: false).success)
  }

  func testAutomaticMountEjectedMeanwhileIsUndone() {
    XCTAssertEqual(
      resolve(.success, userInitiated: false, isSuppressed: true),
      MountResolution(success: false, message: nil, cleanUpMountPoint: true, undoMount: true))
  }

  func testAdoptedMountSucceedsAndDropsOwnFolder() {
    XCTAssertEqual(
      resolve(.adopted),
      MountResolution(success: true, message: nil, cleanUpMountPoint: true, undoMount: false))
  }

  func testTimeoutKeepsFolderOnlyWhileCallMayComplete() {
    let pending = resolve(.timedOut(mayStillComplete: true))
    XCTAssertFalse(pending.success)
    XCTAssertFalse(pending.cleanUpMountPoint)
    XCTAssertEqual(pending.message, NetworkShareMounter.timeoutMessage(for: share))
    XCTAssertTrue(pending.message?.contains("Photos") == true)
    XCTAssertTrue(resolve(.timedOut(mayStillComplete: false)).cleanUpMountPoint)
  }

  func testFailureCarriesItsMessage() {
    XCTAssertEqual(
      resolve(.failed("nope")),
      MountResolution(success: false, message: "nope", cleanUpMountPoint: true, undoMount: false))
  }
}
