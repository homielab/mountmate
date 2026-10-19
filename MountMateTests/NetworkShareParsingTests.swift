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

  func testSMBMountOutputLineMatchesSavedShare() throws {
    let share = NetworkShare(
      name: "public", server: "192.168.1.100", sharePath: "public", username: "user",
      mountAtLogin: false)

    let line =
      "//user@192.168.1.100/public on /Users/me/mountmate/public (smbfs, nodev, nosuid, mounted by me)"
    let mounted = try XCTUnwrap(MountedNetworkShare(mountOutputLine: line))

    XCTAssertEqual(mounted.shareProtocol, .smb)
    XCTAssertTrue(mounted.matches(share))
  }

  func testNFSMountOutputLineIsRecognized() throws {
    let line = "192.168.1.10:/exports/public on /Users/me/mountmate/public (nfs)"
    let mounted = try XCTUnwrap(MountedNetworkShare(mountOutputLine: line))

    XCTAssertEqual(mounted.shareProtocol, .nfs)
    XCTAssertEqual(mounted.source, "192.168.1.10:/exports/public")
    XCTAssertEqual(mounted.mountPoint, "/Users/me/mountmate/public")
  }

  func testAFPMountOutputLineIsRecognized() throws {
    let line = "//admin@tc.local/Data on /Volumes/Data (afpfs, nodev, nosuid)"
    let mounted = try XCTUnwrap(MountedNetworkShare(mountOutputLine: line))

    XCTAssertEqual(mounted.shareProtocol, .afp)
  }

  func testLocalFilesystemLinesAreIgnored() {
    let line = "/dev/disk5s1 on /Volumes/USB (apfs, local, nodev, nosuid, read-only)"
    XCTAssertNil(MountedNetworkShare(mountOutputLine: line))
  }

  func testMountPointContainingFilesystemWordIsNotMismapped() {
    // A mount point like "/Volumes/smbfs Backup" must not fool the parser:
    // the filesystem name is only read from the trailing options.
    let line = "//user@192.168.1.100/public on /Volumes/smbfs Backup (apfs, local)"
    XCTAssertNil(MountedNetworkShare(mountOutputLine: line))
  }

  func testMountPointContainingOnAndParenthesesIsParsed() throws {
    let line =
      "//user@nas/public on /Users/me/Shares on NAS (old) (2) (smbfs, nodev, nosuid, mounted by me)"
    let mounted = try XCTUnwrap(MountedNetworkShare(mountOutputLine: line))

    XCTAssertEqual(mounted.shareProtocol, .smb)
    XCTAssertEqual(mounted.source, "//user@nas/public")
    XCTAssertEqual(mounted.mountPoint, "/Users/me/Shares on NAS (old) (2)")
  }

  func testPercentEncodedSourceIsDecodedForMatching() throws {
    let share = NetworkShare(
      name: "Photos", server: "nas.local", sharePath: "Family Photos", username: "j@doe")
    let line =
      "//j%40doe@nas.local/Family%20Photos on /Users/me/mountmate/Photos (smbfs, nodev, nosuid)"
    let mounted = try XCTUnwrap(MountedNetworkShare(mountOutputLine: line))
    XCTAssertTrue(mounted.matches(share))
  }

  func testHostMatchingIsExact() throws {
    let share = NetworkShare(name: "public", server: "nas", sharePath: "public", username: "")

    func source(_ host: String) throws -> MountedNetworkShare {
      try XCTUnwrap(
        MountedNetworkShare(
          mountOutputLine: "//user@\(host)/public on /Volumes/public (smbfs, nodev, nosuid)"))
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
          mountOutputLine: "//user@\(host)/public on /Volumes/public (smbfs, nodev, nosuid)"))
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
        mountOutputLine: "//user@nas/share/sub on /Users/me/mountmate/sub (smbfs, nodev)"))
    XCTAssertTrue(sub.matches(share))

    let root = try XCTUnwrap(
      MountedNetworkShare(mountOutputLine: "//user@nas/share on /Volumes/share (smbfs, nodev)"))
    XCTAssertFalse(root.matches(share))
  }

  func testSharePathMatchingIsExact() throws {
    let share = NetworkShare(name: "public", server: "nas", sharePath: "public", username: "")

    func source(_ path: String) throws -> MountedNetworkShare {
      try XCTUnwrap(
        MountedNetworkShare(
          mountOutputLine: "//nas/\(path) on /Volumes/x (smbfs, nodev, nosuid)"))
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
        mountOutputLine: "//user@[fe80::1]:445/data on /Volumes/data (smbfs, nodev, nosuid)"))
    XCTAssertEqual(smb.endpoint, MountedNetworkShare.Endpoint(host: "fe80::1", path: "data"))

    let nfs = try XCTUnwrap(
      MountedNetworkShare(mountOutputLine: "[fd00::2]:/exports/public on /Volumes/p (nfs)"))
    XCTAssertEqual(nfs.endpoint, MountedNetworkShare.Endpoint(host: "fd00::2", path: "exports/public"))

    let nfsShare = NetworkShare(
      name: "p", server: "fd00::2", sharePath: "exports/public", username: "",
      shareProtocol: .nfs)
    XCTAssertTrue(nfs.matches(nfsShare))

    let nfsV4 = try XCTUnwrap(
      MountedNetworkShare(mountOutputLine: "10.0.0.5:/exports/public on /Volumes/p (nfs)"))
    XCTAssertEqual(nfsV4.endpoint, MountedNetworkShare.Endpoint(host: "10.0.0.5", path: "exports/public"))
  }

  func testMountPathComparison() {
    XCTAssertTrue(NetworkMountManager.samePath("/Users/me/mountmate/A", "/Users/me/mountmate/a/"))
    XCTAssertTrue(NetworkMountManager.samePath("/Users/me/x/../mountmate/A", "/Users/me/mountmate/A"))
    XCTAssertFalse(NetworkMountManager.samePath("/Users/me/mountmate/A", "/Users/me/mountmate/B"))
  }

  // MARK: - Attribution (exact matches first, then adoptions)

  private func mount(_ line: String) throws -> MountedNetworkShare {
    try XCTUnwrap(MountedNetworkShare(mountOutputLine: line))
  }

  private func adoption(for share: NetworkShare, at mountPoint: String)
    -> NetworkMountManager.Adoption
  {
    NetworkMountManager.Adoption(
      mountPoint: mountPoint, shareProtocol: share.shareProtocol,
      endpoint: MountedNetworkShare.endpoint(for: share))
  }

  func testExactMatchWinsOverEarlierShareWithStaleAdoption() throws {
    // Y is listed first and was once adopted onto X's mount point.
    let y = NetworkShare(name: "Y", server: "serverY", sharePath: "public", username: "")
    let x = NetworkShare(name: "X", server: "serverX", sharePath: "public", username: "")
    let xMount = try mount("//serverX/public on /Users/me/mountmate/X (smbfs, nodev)")

    let result = NetworkMountManager.attributeMounts(
      [xMount], to: [y, x], adoptions: [y.id: adoption(for: y, at: "/Users/me/mountmate/X")])

    XCTAssertEqual(result.owners, [x.id])
    XCTAssertTrue(result.adoptions.isEmpty)
  }

  func testAdoptionClaimsOnlyUnmatchedMounts() throws {
    let share = NetworkShare(name: "NAS", server: "nas", sharePath: "public", username: "")
    // Mounted under its IP address (host differs), adopted at /Volumes/public.
    let ipMount = try mount("//192.168.1.5/public on /Volumes/public (smbfs, nodev)")
    let adoptions = [share.id: adoption(for: share, at: "/Volumes/public")]

    let result = NetworkMountManager.attributeMounts([ipMount], to: [share], adoptions: adoptions)
    XCTAssertEqual(result.owners, [share.id])
    XCTAssertEqual(result.adoptions, adoptions)

    // Once the share also has an exact match, the adoption is not used.
    let exact = try mount("//nas/public on /Users/me/mountmate/NAS (smbfs, nodev)")
    let both = NetworkMountManager.attributeMounts(
      [ipMount, exact], to: [share], adoptions: adoptions)
    XCTAssertEqual(both.owners, [nil, share.id])
    XCTAssertTrue(both.adoptions.isEmpty)
  }

  func testAdoptionIsDroppedWhenEndpointChangesOrMountDisappears() throws {
    let share = NetworkShare(name: "NAS", server: "nas", sharePath: "public", username: "")
    let ipMount = try mount("//192.168.1.5/public on /Volumes/public (smbfs, nodev)")
    let adoptions = [share.id: adoption(for: share, at: "/Volumes/public")]

    var editedServer = share
    editedServer.server = "othernas"
    var editedPath = share
    editedPath.sharePath = "media"
    var editedProtocol = share
    editedProtocol.shareProtocol = .afp

    for edited in [editedServer, editedPath, editedProtocol] {
      let result = NetworkMountManager.attributeMounts(
        [ipMount], to: [edited], adoptions: adoptions)
      XCTAssertEqual(result.owners, [nil])
      XCTAssertTrue(result.adoptions.isEmpty)
    }

    // Share removed.
    let removed = NetworkMountManager.attributeMounts([ipMount], to: [], adoptions: adoptions)
    XCTAssertEqual(removed.owners, [nil])
    XCTAssertTrue(removed.adoptions.isEmpty)

    // Mount gone.
    let gone = NetworkMountManager.attributeMounts([], to: [share], adoptions: adoptions)
    XCTAssertTrue(gone.adoptions.isEmpty)
  }

  func testGuestRetryOnlyForCredentialStyleFailures() {
    XCTAssertTrue(NetworkMountManager.shouldRetryAsGuest(afterStatus: EAUTH))
    XCTAssertTrue(NetworkMountManager.shouldRetryAsGuest(afterStatus: EACCES))
    XCTAssertTrue(NetworkMountManager.shouldRetryAsGuest(afterStatus: EPERM))
    XCTAssertTrue(NetworkMountManager.shouldRetryAsGuest(afterStatus: -128))
    XCTAssertTrue(NetworkMountManager.shouldRetryAsGuest(afterStatus: -5997))
    for status in [0, ETIMEDOUT, ENOENT, EEXIST, EBUSY, -5998, EHOSTUNREACH, ENETUNREACH,
      ECONNREFUSED]
    {
      XCTAssertFalse(NetworkMountManager.shouldRetryAsGuest(afterStatus: status))
    }
  }

  func testUsernamePlacementForNetFS() {
    func placement(_ username: String, _ shareProtocol: ShareProtocol = .smb)
      -> (urlUser: String?, user: String?)
    {
      NetworkMountManager.netFSUserPlacement(
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

  func testMalformedLinesAreIgnored() {
    XCTAssertNil(MountedNetworkShare(mountOutputLine: "no separator here (smbfs)"))
    XCTAssertNil(MountedNetworkShare(mountOutputLine: "unclosed paren (smbfs"))
    XCTAssertNil(MountedNetworkShare(mountOutputLine: ""))
  }
}
