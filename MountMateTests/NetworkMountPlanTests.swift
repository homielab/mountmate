//  Created by homielab.com

import NetFS
import XCTest

@testable import MountMate

final class NetworkMountPlanTests: XCTestCase {
  private let share = NetworkShare(
    name: "Photos", server: "nas.local", sharePath: "photos", username: "",
    shareProtocol: .smb)

  // MARK: stalled mounts

  func testAutomaticMountAlwaysWaitsForStalledCall() {
    XCTAssertTrue(NetworkMountPlan.shouldBlock(stallAge: 0, userInitiated: false))
    XCTAssertTrue(
      NetworkMountPlan.shouldBlock(
        stallAge: NetworkMountPlan.stalledMountRetryAge * 10, userInitiated: false))
  }

  func testUserMountWaitsUntilStallIsOldEnough() {
    let age = NetworkMountPlan.stalledMountRetryAge
    XCTAssertTrue(NetworkMountPlan.shouldBlock(stallAge: age - 1, userInitiated: true))
    XCTAssertFalse(NetworkMountPlan.shouldBlock(stallAge: age, userInitiated: true))
    XCTAssertFalse(NetworkMountPlan.shouldBlock(stallAge: age + 60, userInitiated: true))
  }

  // MARK: preflight

  private func preflight(
    stallAge: TimeInterval? = nil, userInitiated: Bool = true,
    mountTable: [MountedNetworkShare]? = nil, existingMount: MountedNetworkShare? = nil,
    mountPoint: String = "/Users/me/mountmate/photos"
  ) -> NetworkMountPlan.Preflight {
    NetworkMountPlan.preflight(
      share: share, mountPoint: mountPoint, userInitiated: userInitiated,
      stallAge: stallAge, mountTable: mountTable, existingMount: existingMount)
  }

  func testEmptyPreflightProceeds() {
    XCTAssertEqual(preflight(), .proceed)
  }

  func testFreshStallBlocksEveryInitiator() {
    if case .blocked(let message) = preflight(stallAge: 5, userInitiated: false) {
      XCTAssertTrue(message.contains("Photos"))
    } else {
      XCTFail("a fresh stall must block")
    }
    if case .blocked(let message) = preflight(
      stallAge: NetworkMountPlan.stalledMountRetryAge - 1, userInitiated: true)
    {
      XCTAssertTrue(message.contains("still in progress"))
    } else {
      XCTFail("a young stall must block a user mount too")
    }
  }

  func testOldStallLetsTheUserThrough() {
    XCTAssertEqual(
      preflight(stallAge: NetworkMountPlan.stalledMountRetryAge, userInitiated: true),
      .proceed)
    // Automatic mounts wait no matter how old the stall is.
    if case .blocked = preflight(
      stallAge: NetworkMountPlan.stalledMountRetryAge * 10, userInitiated: false)
    {
    } else {
      XCTFail("an automatic mount must wait for a stalled call")
    }
  }

  func testAlreadyMountedComesBeforeTheOccupiedCheck() {
    guard
      let own = MountedNetworkShare(
        source: "smb://nas/photos", mountPoint: "/Volumes/photos", fileSystemType: "smbfs")
    else { return XCTFail("a valid smb mount parses") }
    XCTAssertEqual(preflight(existingMount: own), .alreadyMounted)
  }

  func testOccupiedMountPointIsBlockedWithTheRedactedSource() {
    guard
      let occupant = MountedNetworkShare(
        source: "smb://bob:secret@nas/other", mountPoint: "/Users/me/mountmate/photos",
        fileSystemType: "smbfs")
    else { return XCTFail("a valid smb mount parses") }
    if case .blocked(let message) = preflight(mountTable: [occupant]) {
      XCTAssertTrue(message.contains("bob:***@nas/other"), message)
    } else {
      XCTFail("an occupied mount point must block")
    }
  }

  // MARK: mount result to message and clean-up

  private func resolve(
    _ outcome: MountOutcome, userInitiated: Bool = true,
    isSuppressed: Bool = false
  ) -> MountResolution {
    NetworkMountPlan.resolution(
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
    XCTAssertEqual(pending.message, NetworkMountPlan.timeoutMessage(for: share))
    XCTAssertTrue(pending.message?.contains("Photos") == true)
    XCTAssertTrue(resolve(.timedOut(mayStillComplete: false)).cleanUpMountPoint)
  }

  func testAFPTimeoutMessageExplainsDeprecation() {
    let afpShare = NetworkShare(
      name: "TimeCapsule", server: "tc", sharePath: "backup", username: "user",
      shareProtocol: .afp)
    let msg = NetworkMountPlan.timeoutMessage(for: afpShare)
    XCTAssertTrue(msg.contains("TimeCapsule"))
    XCTAssertTrue(msg.contains("Apple has removed support for AFP"))
  }

  func testFailureCarriesItsMessage() {
    XCTAssertEqual(
      resolve(.failed("nope")),
      MountResolution(success: false, message: "nope", cleanUpMountPoint: true, undoMount: false))
  }

  // MARK: NFS failure message

  private let nfsShare = NetworkShare(
    name: "Export", server: "nas", sharePath: "export", username: "", shareProtocol: .nfs)

  func testNFSFailureWithoutStderrNamesTheExitCode() {
    XCTAssertEqual(
      NetworkMountPlan.nfsFailureMessage(
        stderr: "", executable: "/sbin/mount_nfs", exitCode: 2,
        share: nfsShare, mountPoint: "/mp"),
      "/sbin/mount_nfs exited with code 2.")
  }

  func testNFSFailureRedactsPasswords() {
    let message = NetworkMountPlan.nfsFailureMessage(
      stderr: "mount failed: smb://bob:secret@nas/share", executable: "/sbin/mount_nfs",
      exitCode: 1, share: nfsShare, mountPoint: "/mp")
    XCTAssertFalse(message.contains("secret"), message)
  }

  func testNFSPermissionFailureGetsTheLocationGuidance() {
    for stderr in ["operation not permitted", "Permission denied", "not owner"] {
      let message = NetworkMountPlan.nfsFailureMessage(
        stderr: stderr, executable: "/sbin/mount_nfs", exitCode: 1,
        share: nfsShare, mountPoint: "/Users/me/mountmate/export")
      XCTAssertTrue(message.contains("administrator privileges"), stderr)
    }
  }

  // MARK: mount point creation failure

  func testNoPermissionNamesTheAdministratorGuidance() {
    let message = NetworkMountPlan.mountPointCreationFailureMessage(
      error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
      mountPoint: "/Volumes/x", shareName: "Photos")
    XCTAssertTrue(message.contains("administrator privileges"), message)
    XCTAssertTrue(message.contains("/Volumes/x"))
    XCTAssertTrue(message.contains("Photos"))
    let missing = NetworkMountPlan.mountPointCreationFailureMessage(
      error: NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
      mountPoint: "/Volumes/x", shareName: "Photos")
    XCTAssertTrue(missing.contains("administrator privileges"))
  }

  func testOtherErrorsCarryTheSystemMessage() {
    let message = NetworkMountPlan.mountPointCreationFailureMessage(
      error: NSError(
        domain: "test", code: 7,
        userInfo: [
          NSLocalizedDescriptionKey: "disk full"
        ]),
      mountPoint: "/mp", shareName: "Photos")
    XCTAssertTrue(message.contains("Failed to create mount point"), message)
    XCTAssertTrue(message.contains("disk full"))
  }

  // MARK: NetFS options

  func testOpenOptionsShowNoUIAndAddGuestOnlyWhenAsked() {
    let plain = NetworkMountPlan.netFSOpenOptions(asGuest: false)
    XCTAssertEqual(plain[kNAUIOptionKey as String] as? String, kNAUIOptionNoUI as String)
    XCTAssertNil(plain[kNetFSUseGuestKey as String])

    let guest = NetworkMountPlan.netFSOpenOptions(asGuest: true)
    XCTAssertEqual(guest[kNetFSUseGuestKey as String] as? Bool, true)
  }

  func testMountOptionsPinTheFolderAndKeepTheOldFlags() {
    func flags(for proto: ShareProtocol) -> Int32 {
      let share = NetworkShare(
        name: "s", server: "nas", sharePath: "photos", username: "", shareProtocol: proto)
      let options = NetworkMountPlan.netFSMountOptions(for: share)
      XCTAssertEqual(options[kNetFSMountAtMountDirKey as String] as? Bool, true)
      XCTAssertEqual(options[kNetFSAllowSubMountsKey as String] as? Bool, true)
      return (options[kNetFSMountFlagsKey as String] as? NSNumber)?.int32Value ?? 0
    }
    XCTAssertEqual(flags(for: .afp), MNT_NOSUID | MNT_NODEV)
    XCTAssertEqual(flags(for: .smb), MNT_NOSUID | MNT_NODEV | MNT_UNKNOWNPERMISSIONS)
    XCTAssertEqual(flags(for: .nfs), MNT_NOSUID | MNT_NODEV)
  }

  // MARK: NFS arguments

  func testNFSArgumentsUseTheCanonicalExportForm() {
    let share = NetworkShare(
      name: "s", server: "nas", sharePath: "export/data", username: "", shareProtocol: .nfs)
    XCTAssertEqual(
      NetworkMountPlan.nfsArguments(share: share, mountPoint: "/mp"),
      ["-o", "resvport", "nas:/export/data", "/mp"])
    let slashed = NetworkShare(
      name: "s", server: "nas", sharePath: "//export//", username: "", shareProtocol: .nfs)
    XCTAssertEqual(
      NetworkMountPlan.nfsArguments(share: slashed, mountPoint: "/mp"),
      ["-o", "resvport", "nas:/export", "/mp"])
  }

  // MARK: Keychain failure

  func testKeychainFailureNamesTheShareAndStatus() {
    let message = NetworkMountPlan.keychainFailureMessage(for: share, status: -25291)
    XCTAssertTrue(message.contains("Photos"), message)
    XCTAssertTrue(message.contains("-25291"), message)
  }

  // MARK: finding the share's own mount

  private func mounted(
    _ source: String, _ mountPoint: String, _ type: String = "smbfs"
  ) -> MountedNetworkShare? {
    MountedNetworkShare(source: source, mountPoint: mountPoint, fileSystemType: type)
  }

  func testAtOurOwnFolderTheSharePathSuffices() {
    // Another server's share of the same name is on our folder only because
    // of a name collision; at our own folder only MountMate mounts, so the
    // protocol and share path are the identity.
    guard let collision = mounted("//other/photos", "/Users/me/mountmate/photos") else {
      return XCTFail("a valid smb mount parses")
    }
    XCTAssertEqual(
      NetworkMountPlan.mountOfSameShare(
        share, ownMountPoint: "/Users/me/mountmate/photos", mountTable: [collision]),
      collision)
  }

  func testElsewhereTheHostMustMatchToo() {
    guard let same = mounted("//nas/photos", "/Volumes/photos"),
      let foreign = mounted("//other/photos", "/Volumes/elsewhere")
    else { return XCTFail("a valid smb mount parses") }
    XCTAssertEqual(
      NetworkMountPlan.mountOfSameShare(
        share, ownMountPoint: "/Users/me/mountmate/photos", mountTable: [same, foreign]),
      same)
    XCTAssertNil(
      NetworkMountPlan.mountOfSameShare(
        share, ownMountPoint: "/Users/me/mountmate/photos", mountTable: [foreign]))
    // An unreadable mount table links nothing.
    XCTAssertNil(
      NetworkMountPlan.mountOfSameShare(
        share, ownMountPoint: "/Users/me/mountmate/photos", mountTable: nil))
  }
}
