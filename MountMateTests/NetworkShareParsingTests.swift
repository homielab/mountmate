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

  func testMalformedLinesAreIgnored() {
    XCTAssertNil(MountedNetworkShare(mountOutputLine: "no separator here (smbfs)"))
    XCTAssertNil(MountedNetworkShare(mountOutputLine: "unclosed paren (smbfs"))
    XCTAssertNil(MountedNetworkShare(mountOutputLine: ""))
  }
}
