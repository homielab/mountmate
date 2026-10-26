//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkShareParsingTests: XCTestCase {
  func testProtocolMappingFromMountFilesystemNames() {
    XCTAssertEqual(ShareProtocol.from(mountFilesystemName: "smbfs"), .smb)
    XCTAssertEqual(ShareProtocol.from(mountFilesystemName: "nfs"), .nfs)
    XCTAssertEqual(ShareProtocol.from(mountFilesystemName: "afpfs"), .afp)
    XCTAssertNil(ShareProtocol.from(mountFilesystemName: "apfs"))
    XCTAssertNil(ShareProtocol.from(mountFilesystemName: "hfs"))
    XCTAssertNil(ShareProtocol.from(mountFilesystemName: "exfat"))
    XCTAssertNil(ShareProtocol.from(mountFilesystemName: "ntfs"))
    XCTAssertNil(ShareProtocol.from(mountFilesystemName: "msdos"))
  }

  func testProtocolMetadataConsistency() {
    for shareProtocol in ShareProtocol.allCases {
      XCTAssertEqual(
        ShareProtocol.from(mountFilesystemName: shareProtocol.mountFilesystemName),
        shareProtocol,
        "\(shareProtocol) must map back from its own mount filesystem name")
      XCTAssertFalse(shareProtocol.displayName.isEmpty)
      XCTAssertFalse(shareProtocol.urlScheme.isEmpty)
    }
    XCTAssertFalse(ShareProtocol.nfs.supportsUserCredentials)
    XCTAssertTrue(ShareProtocol.smb.supportsUserCredentials)
    XCTAssertTrue(ShareProtocol.afp.supportsUserCredentials)
  }

  func testSMBMountEntryMatchesSavedShare() throws {
    let share = NetworkShare(
      name: "public", server: "192.168.1.100", sharePath: "public", username: "user",
      mountAtLogin: false)

    let mounted = try XCTUnwrap(
      MountedNetworkShare(
        source: "//user@192.168.1.100/public", mountPoint: "/Users/me/mountmate/public",
        fileSystemType: "smbfs"))

    XCTAssertEqual(mounted.shareProtocol, .smb)
    XCTAssertTrue(mounted.matches(share))
  }

  func testNFSMountEntryIsRecognized() throws {
    let mounted = try XCTUnwrap(
      MountedNetworkShare(
        source: "192.168.1.10:/exports/public", mountPoint: "/Users/me/mountmate/public",
        fileSystemType: "nfs"))

    XCTAssertEqual(mounted.shareProtocol, .nfs)
    XCTAssertEqual(mounted.source, "192.168.1.10:/exports/public")
    XCTAssertEqual(mounted.mountPoint, "/Users/me/mountmate/public")
  }

  func testAFPMountEntryIsRecognized() throws {
    let mounted = try XCTUnwrap(
      MountedNetworkShare(
        source: "//admin@tc.local/Data", mountPoint: "/Volumes/Data", fileSystemType: "afpfs"))

    XCTAssertEqual(mounted.shareProtocol, .afp)
  }

  func testLocalFilesystemEntriesAreIgnored() {
    XCTAssertNil(
      MountedNetworkShare(
        entry: MountEntry(
          source: "/dev/disk5s1", mountPoint: "/Volumes/USB", fileSystemType: "apfs")
      ))
  }

  func testMountPointContainingFilesystemWordIsNotMismapped() {
    // Only the filesystem type decides the protocol, never the mount point.
    XCTAssertNil(
      MountedNetworkShare(
        source: "//user@192.168.1.100/public", mountPoint: "/Volumes/smbfs Backup",
        fileSystemType: "apfs"))
  }

  func testMountPointContainingOnAndParenthesesIsParsed() throws {
    let mounted = try XCTUnwrap(
      MountedNetworkShare(
        source: "//user@nas/public", mountPoint: "/Users/me/Shares on NAS (old) (2)",
        fileSystemType: "smbfs"))

    XCTAssertEqual(mounted.shareProtocol, .smb)
    XCTAssertEqual(mounted.source, "//user@nas/public")
    XCTAssertEqual(mounted.mountPoint, "/Users/me/Shares on NAS (old) (2)")
  }

  func testPercentEncodedSourceIsDecodedForMatching() throws {
    let share = NetworkShare(
      name: "Photos", server: "nas.local", sharePath: "Family Photos", username: "j@doe")
    let mounted = try XCTUnwrap(
      MountedNetworkShare(
        source: "//j%40doe@nas.local/Family%20Photos", mountPoint: "/Users/me/mountmate/Photos",
        fileSystemType: "smbfs"))
    XCTAssertTrue(mounted.matches(share))
  }

  func testHostMatchingIsExact() throws {
    let share = NetworkShare(name: "public", server: "nas", sharePath: "public", username: "")

    func source(_ host: String) throws -> MountedNetworkShare {
      try XCTUnwrap(
        MountedNetworkShare(
          source: "//user@\(host)/public", mountPoint: "/Volumes/public", fileSystemType: "smbfs"))
    }

    XCTAssertTrue(try source("nas").matches(share))
    XCTAssertTrue(try source("NAS").matches(share))
    XCTAssertTrue(try source("nas.").matches(share))
    XCTAssertTrue(try source("nas:445").matches(share))
    XCTAssertFalse(try source("nas2").matches(share))
    XCTAssertFalse(try source("nas.backup.lan").matches(share))
    XCTAssertFalse(try source("mynas").matches(share))

    // A server entered with a user name or port still matches.
    let withUser = NetworkShare(
      name: "public", server: "admin@nas:445", sharePath: "public", username: "")
    XCTAssertTrue(try source("nas").matches(withUser))
  }

  func testBonjourAndLocalHostFormsMatch() throws {
    let share = NetworkShare(name: "public", server: "nas", sharePath: "public", username: "")

    func source(_ host: String) throws -> MountedNetworkShare {
      try XCTUnwrap(
        MountedNetworkShare(
          source: "//user@\(host)/public", mountPoint: "/Volumes/public", fileSystemType: "smbfs"))
    }

    XCTAssertTrue(try source("NAS._smb._tcp.local").matches(share))
    XCTAssertTrue(try source("nas.local").matches(share))
    XCTAssertFalse(try source("nas2._smb._tcp.local").matches(share))
    XCTAssertFalse(try source("nas.backup.lan").matches(share))

    let localShare = NetworkShare(
      name: "public", server: "nas.local", sharePath: "public", username: "")
    XCTAssertTrue(try source("nas").matches(localShare))
  }

  func testSubfolderShareMatchesFullMountedPath() throws {
    let share = NetworkShare(name: "sub", server: "nas", sharePath: "share/sub", username: "")
    let sub = try XCTUnwrap(
      MountedNetworkShare(
        source: "//user@nas/share/sub", mountPoint: "/Users/me/mountmate/sub",
        fileSystemType: "smbfs"))
    XCTAssertTrue(sub.matches(share))

    let root = try XCTUnwrap(
      MountedNetworkShare(
        source: "//user@nas/share", mountPoint: "/Volumes/share", fileSystemType: "smbfs"))
    XCTAssertFalse(root.matches(share))
  }

  func testSharePathMatchingIsExact() throws {
    let share = NetworkShare(name: "public", server: "nas", sharePath: "public", username: "")

    func source(_ path: String) throws -> MountedNetworkShare {
      try XCTUnwrap(
        MountedNetworkShare(
          source: "//nas/\(path)", mountPoint: "/Volumes/x", fileSystemType: "smbfs"))
    }

    XCTAssertTrue(try source("public").matches(share))
    XCTAssertTrue(try source("PUBLIC").matches(share))
    XCTAssertFalse(try source("public2").matches(share))
    XCTAssertFalse(try source("other/public").matches(share))
    XCTAssertFalse(try source("public/sub").matches(share))
  }

  func testIPv6AndNFSSourcesAreParsed() throws {
    let smb = try XCTUnwrap(
      MountedNetworkShare(
        source: "//user@[fe80::1]:445/data", mountPoint: "/Volumes/data", fileSystemType: "smbfs"))
    XCTAssertEqual(smb.endpoint, MountedNetworkShare.Endpoint(host: "fe80::1", path: "data"))

    let nfs = try XCTUnwrap(
      MountedNetworkShare(
        source: "[fd00::2]:/exports/public", mountPoint: "/Volumes/p", fileSystemType: "nfs"))
    XCTAssertEqual(
      nfs.endpoint, MountedNetworkShare.Endpoint(host: "fd00::2", path: "exports/public"))

    let nfsShare = NetworkShare(
      name: "p", server: "fd00::2", sharePath: "exports/public", username: "",
      shareProtocol: .nfs)
    XCTAssertTrue(nfs.matches(nfsShare))

    let nfsV4 = try XCTUnwrap(
      MountedNetworkShare(
        source: "10.0.0.5:/exports/public", mountPoint: "/Volumes/p", fileSystemType: "nfs"))
    XCTAssertEqual(
      nfsV4.endpoint, MountedNetworkShare.Endpoint(host: "10.0.0.5", path: "exports/public"))
  }

  func testMountPathComparison() {
    XCTAssertTrue(NetworkMountTable.samePath("/Users/me/mountmate/A", "/Users/me/mountmate/a/"))
    XCTAssertTrue(
      NetworkMountTable.samePath("/Users/me/x/../mountmate/A", "/Users/me/mountmate/A"))
    XCTAssertFalse(NetworkMountTable.samePath("/Users/me/mountmate/A", "/Users/me/mountmate/B"))
  }

  // MARK: - Attribution (exact matches first, then adoptions)

  private func mount(_ source: String, at mountPoint: String, _ fileSystemType: String)
    throws -> MountedNetworkShare
  {
    try XCTUnwrap(
      MountedNetworkShare(source: source, mountPoint: mountPoint, fileSystemType: fileSystemType))
  }

  private func adoption(for share: NetworkShare, at mountPoint: String)
    -> ShareAdoption.Adoption
  {
    ShareAdoption.Adoption(
      mountPoint: mountPoint, shareProtocol: share.shareProtocol,
      endpoint: MountedNetworkShare.endpoint(for: share))
  }

  func testExactMatchWinsOverEarlierShareWithStaleAdoption() throws {
    // Y is listed first and was once adopted onto X's mount point.
    let y = NetworkShare(name: "Y", server: "serverY", sharePath: "public", username: "")
    let x = NetworkShare(name: "X", server: "serverX", sharePath: "public", username: "")
    let xMount = try mount("//serverX/public", at: "/Users/me/mountmate/X", "smbfs")

    let result = ShareAdoption.attributeMounts(
      [xMount], to: [y, x], adoptions: [y.id: adoption(for: y, at: "/Users/me/mountmate/X")])

    XCTAssertEqual(result.owners, [x.id])
    XCTAssertTrue(result.adoptions.isEmpty)
  }

  func testAdoptionClaimsOnlyUnmatchedMounts() throws {
    let share = NetworkShare(name: "NAS", server: "nas", sharePath: "public", username: "")
    // Mounted under its IP address (host differs), adopted at /Volumes/public.
    let ipMount = try mount("//192.168.1.5/public", at: "/Volumes/public", "smbfs")
    let adoptions = [share.id: adoption(for: share, at: "/Volumes/public")]

    let result = ShareAdoption.attributeMounts([ipMount], to: [share], adoptions: adoptions)
    XCTAssertEqual(result.owners, [share.id])
    XCTAssertEqual(result.adoptions, adoptions)

    // Once the share also has an exact match, the adoption is not used.
    let exact = try mount("//nas/public", at: "/Users/me/mountmate/NAS", "smbfs")
    let both = ShareAdoption.attributeMounts(
      [ipMount, exact], to: [share], adoptions: adoptions)
    XCTAssertEqual(both.owners, [nil, share.id])
    XCTAssertTrue(both.adoptions.isEmpty)
  }

  func testAdoptionIsDroppedWhenEndpointChangesOrMountDisappears() throws {
    let share = NetworkShare(name: "NAS", server: "nas", sharePath: "public", username: "")
    let ipMount = try mount("//192.168.1.5/public", at: "/Volumes/public", "smbfs")
    let adoptions = [share.id: adoption(for: share, at: "/Volumes/public")]

    var editedServer = share
    editedServer.server = "othernas"
    var editedPath = share
    editedPath.sharePath = "media"
    var editedProtocol = share
    editedProtocol.shareProtocol = .afp

    for edited in [editedServer, editedPath, editedProtocol] {
      let result = ShareAdoption.attributeMounts(
        [ipMount], to: [edited], adoptions: adoptions)
      XCTAssertEqual(result.owners, [nil])
      XCTAssertTrue(result.adoptions.isEmpty)
    }

    // Share removed.
    let removed = ShareAdoption.attributeMounts([ipMount], to: [], adoptions: adoptions)
    XCTAssertEqual(removed.owners, [nil])
    XCTAssertTrue(removed.adoptions.isEmpty)

    // Mount gone.
    let gone = ShareAdoption.attributeMounts([], to: [share], adoptions: adoptions)
    XCTAssertTrue(gone.adoptions.isEmpty)
  }

  func testGuestRetryOnlyForCredentialStyleFailures() {
    XCTAssertTrue(NetworkShareMounter.shouldRetryAsGuest(afterStatus: EAUTH))
    XCTAssertTrue(NetworkShareMounter.shouldRetryAsGuest(afterStatus: EACCES))
    XCTAssertTrue(NetworkShareMounter.shouldRetryAsGuest(afterStatus: EPERM))
    XCTAssertTrue(NetworkShareMounter.shouldRetryAsGuest(afterStatus: -128))
    XCTAssertTrue(NetworkShareMounter.shouldRetryAsGuest(afterStatus: -5997))
    for status in [
      0, ETIMEDOUT, ENOENT, EEXIST, EBUSY, -5998, EHOSTUNREACH, ENETUNREACH,
      ECONNREFUSED,
    ] {
      XCTAssertFalse(NetworkShareMounter.shouldRetryAsGuest(afterStatus: status))
    }
  }

  func testUsernamePlacementForNetFS() {
    func placement(_ username: String, _ shareProtocol: ShareProtocol = .smb)
      -> (urlUser: String?, user: String?)
    {
      NetworkShareMounter.netFSUserPlacement(
        for: NetworkShare(
          name: "s", server: "nas", sharePath: "s", username: username,
          shareProtocol: shareProtocol))
    }
    XCTAssertTrue(placement("") == (nil, nil))
    XCTAssertTrue(placement("alice") == (nil, "alice"))
    XCTAssertTrue(placement("alice@corp.example") == (nil, "alice@corp.example"))
    XCTAssertTrue(placement("CORP;alice") == ("CORP;alice", nil))
    XCTAssertTrue(placement("CORP\\alice") == ("CORP;alice", nil))
    XCTAssertTrue(placement("CORP\\alice", .afp) == (nil, "CORP\\alice"))
  }

  func testSMBLoginPartsSplitsDomainForms() {
    func parts(_ username: String) -> (domain: String?, user: String) {
      NetworkMountManager.smbLoginParts(username)
    }
    XCTAssertTrue(parts("CORP\\alice") == ("CORP", "alice"))
    XCTAssertTrue(parts("CORP;alice") == ("CORP", "alice"))
    XCTAssertTrue(parts("alice@corp.example") == ("corp.example", "alice"))
    XCTAssertTrue(parts("first.last@sub@corp.example") == ("corp.example", "first.last@sub"))
    XCTAssertTrue(parts("alice") == (nil, "alice"))
    XCTAssertTrue(parts("") == (nil, ""))
    XCTAssertTrue(parts("CORP\\") == (nil, "CORP\\"))
    XCTAssertTrue(parts("@corp") == (nil, "@corp"))
  }

  /// Renders a NetFS failure with keys as text, independent of the
  /// system language.
  private func failureMessage(
    _ status: Int32, username: String = "alice", shareProtocol: ShareProtocol = .smb,
    mountPoint: String = "/Users/test/mountmate/Data"
  ) -> String {
    NetworkMountManager.netFSErrorMessage(
      status,
      share: NetworkShare(
        name: "Data", server: "fs01", sharePath: "data", username: username,
        shareProtocol: shareProtocol),
      mountPoint: mountPoint, homeDirectory: "/Users/test", localize: { $0 })
  }

  func testNetFSFailureMessagesNameCauseAndCode() {
    let expectations: [(Int32, String, String)] = [
      (EAUTH, "Authentication failed", "Error code: 80 (EAUTH)"),
      (EACCES, "was denied by the server", "Error code: 13 (EACCES)"),
      (ENOENT, "was not found on the server", "Error code: 2 (ENOENT)"),
      (ETIMEDOUT, "timed out", "Error code: 60 (ETIMEDOUT)"),
      (EHOSTUNREACH, "Could not connect to the server", "Error code: 65 (EHOSTUNREACH)"),
      (ECONNREFUSED, "refused the connection", "Error code: 61 (ECONNREFUSED)"),
      (EEXIST, "is already connected", "Error code: 17 (EEXIST)"),
      (EBUSY, "Another volume is already mounted", "Error code: 16 (EBUSY)"),
      (-128, "requires a username and password", "Error code: -128 (userCanceledErr)"),
      (-5045, "has expired or must be changed", "Error code: -5045 (ENETFSPWDNEEDSCHANGE)"),
      (-5046, "password policy", "Error code: -5046 (ENETFSPWDPOLICY)"),
      (-5999, "is restricted", "Error code: -5999 (ENETFSACCOUNTRESTRICTED)"),
      (-5998, "no shares available", "Error code: -5998 (ENETFSNOSHARESAVAIL)"),
      (-5997, "no sign-in method", "Error code: -5997 (ENETFSNOAUTHMECHSUPP)"),
      (-5996, "SMB 2 or SMB 3", "Error code: -5996 (ENETFSNOPROTOVERSSUPP)"),
    ]
    for (status, cause, code) in expectations {
      let message = failureMessage(status)
      XCTAssertTrue(message.contains(cause), "\(status): \(message)")
      XCTAssertTrue(message.hasSuffix(code), "\(status): \(message)")
    }
  }

  func testNetFSFailureMessageHintsAtDomainLogin() {
    let plain = failureMessage(EAUTH, username: "alice")
    XCTAssertTrue(plain.contains("DOMAIN\\user or user@domain"), plain)

    for username in ["CORP\\alice", "alice@CORP"] {
      let withDomain = failureMessage(EACCES, username: username)
      XCTAssertTrue(withDomain.contains("as “alice” in the domain “CORP”"), withDomain)
      XCTAssertFalse(withDomain.contains("DOMAIN\\user"), withDomain)
      XCTAssertTrue(withDomain.contains("SMB 2 or SMB 3"), withDomain)
    }

    // AFP has no Windows domains; no username means no login to explain.
    XCTAssertFalse(failureMessage(EAUTH, shareProtocol: .afp).contains("domain"))
    XCTAssertFalse(failureMessage(EAUTH, username: "").contains("domain"))
  }

  func testNetFSAccessDeniedOutsideHomeBlamesTheMountLocation() {
    let message = failureMessage(EACCES, mountPoint: "/Volumes/Data")
    XCTAssertTrue(message.contains("requires administrator privileges"), message)
    XCTAssertTrue(message.hasSuffix("Error code: 13 (EACCES)"), message)
  }

  func testUnknownNetFSStatusKeepsGenericMessage() {
    XCTAssertEqual(failureMessage(-36), "Could not mount “Data” (error -36).")
    XCTAssertNil(NetworkMountManager.netFSStatusName(-36))
  }

  func testEntriesWithoutSourceOrMountPointAreIgnored() {
    XCTAssertNil(MountedNetworkShare(source: "", mountPoint: "/Volumes/x", fileSystemType: "smbfs"))
    XCTAssertNil(MountedNetworkShare(source: "//nas/x", mountPoint: "", fileSystemType: "smbfs"))
    XCTAssertNil(
      MountedNetworkShare(source: "//nas/x", mountPoint: "/Volumes/x", fileSystemType: ""))
  }
}
