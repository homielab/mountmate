//  Created by homielab.com

import XCTest

@testable import MountMate

final class MountTableTests: XCTestCase {
  // MARK: - Reading the kernel mount table

  func testEntriesIncludeTheRootVolume() throws {
    let entries = try XCTUnwrap(MountTable.entries())
    let root = try XCTUnwrap(entries.first { $0.mountPoint == "/" })
    XCTAssertFalse(root.source.isEmpty)
    XCTAssertFalse(root.fileSystemType.isEmpty)
  }

  func testNetworkSharesOfThisMacAreOnlyNetworkProtocols() throws {
    let entries = try XCTUnwrap(MountTable.entries())
    let shares = try XCTUnwrap(MountTable.networkShares())
    XCTAssertLessThanOrEqual(shares.count, entries.count)
    for share in shares {
      XCTAssertTrue(
        entries.contains { $0.mountPoint == share.mountPoint && $0.source == share.source })
    }
  }

  func testNetworkSharesKeepTableOrderAndSkipLocalFileSystems() {
    let entries = [
      MountEntry(source: "/dev/disk3s1s1", mountPoint: "/", fileSystemType: "apfs"),
      MountEntry(source: "//bob@nas/media", mountPoint: "/Volumes/media", fileSystemType: "smbfs"),
      MountEntry(source: "devfs", mountPoint: "/dev", fileSystemType: "devfs"),
      MountEntry(source: "nas:/exports/backup", mountPoint: "/Users/me/b", fileSystemType: "nfs"),
      MountEntry(source: "//tc.local/Data", mountPoint: "/Volumes/Data", fileSystemType: "afpfs"),
    ]
    let shares = MountTable.networkShares(in: entries)
    XCTAssertEqual(shares.map(\.shareProtocol), [.smb, .nfs, .afp])
    XCTAssertEqual(shares.map(\.mountPoint), ["/Volumes/media", "/Users/me/b", "/Volumes/Data"])
  }

  func testEntryReadsStatfsFields() {
    var stat = statfs()
    write("//bob@nas/Family%20Photos", into: &stat.f_mntfromname)
    write("/Users/me/mountmate/Photos (old) on NAS", into: &stat.f_mntonname)
    write("smbfs", into: &stat.f_fstypename)

    XCTAssertEqual(
      MountTable.entry(from: stat),
      MountEntry(
        source: "//bob@nas/Family%20Photos", mountPoint: "/Users/me/mountmate/Photos (old) on NAS",
        fileSystemType: "smbfs"))
  }

  func testEntryReadsReadOnlyFlag() {
    var stat = statfs()
    write("/dev/disk4s1", into: &stat.f_mntfromname)
    write("/Volumes/Backup", into: &stat.f_mntonname)
    write("msdos", into: &stat.f_fstypename)
    XCTAssertFalse(MountTable.entry(from: stat).isReadOnly)

    stat.f_flags = UInt32(MNT_RDONLY) | UInt32(MNT_NOSUID)
    XCTAssertTrue(MountTable.entry(from: stat).isReadOnly)
    stat.f_flags = UInt32(MNT_NOSUID)
    XCTAssertFalse(MountTable.entry(from: stat).isReadOnly)
  }

  func testReadOnlyMountPointsListsOnlyReadOnlyEntries() {
    let entries = [
      MountEntry(
        source: "/dev/disk3s1s1", mountPoint: "/", fileSystemType: "apfs", isReadOnly: true),
      MountEntry(source: "/dev/disk4s1", mountPoint: "/Volumes/Data", fileSystemType: "exfat"),
      MountEntry(
        source: "/dev/disk5s1", mountPoint: "/Volumes/Backup", fileSystemType: "hfs",
        isReadOnly: true),
    ]
    XCTAssertEqual(MountTable.readOnlyMountPoints(in: entries), ["/", "/Volumes/Backup"])
  }

  func testFileSystemTypesByMountPointKeepTheTopmostEntry() {
    let entries = [
      MountEntry(source: "/dev/disk4s1", mountPoint: "/Volumes/Win", fileSystemType: "ntfs"),
      MountEntry(source: "/dev/disk5s1", mountPoint: "/Volumes/Data", fileSystemType: "exfat"),
      MountEntry(source: "/dev/disk4s1", mountPoint: "/Volumes/Win", fileSystemType: "ufsd_NTFS"),
    ]
    XCTAssertEqual(
      MountTable.fileSystemTypes(in: entries),
      ["/Volumes/Win": "ufsd_NTFS", "/Volumes/Data": "exfat"])
  }

  func testEntryKeepsNonASCIIMountPoints() {
    var stat = statfs()
    write("//nas/ảnh", into: &stat.f_mntfromname)
    write("/Users/me/mountmate/Ảnh gia đình", into: &stat.f_mntonname)
    write("smbfs", into: &stat.f_fstypename)

    XCTAssertEqual(MountTable.entry(from: stat).mountPoint, "/Users/me/mountmate/Ảnh gia đình")
  }

  func testCharacterArrayStopsAtFirstNUL() {
    let characters: (CChar, CChar, CChar, CChar, CChar) = (110, 102, 115, 0, 120)
    XCTAssertEqual(MountTable.string(fromCharacters: characters), "nfs")
  }

  func testCharacterArrayWithoutTerminatorIsReadToItsEnd() {
    let characters: (CChar, CChar, CChar) = (110, 102, 115)
    XCTAssertEqual(MountTable.string(fromCharacters: characters), "nfs")
    let empty: (CChar, CChar) = (0, 0)
    XCTAssertEqual(MountTable.string(fromCharacters: empty), "")
  }

  /// Writes `text` NUL-terminated into a fixed-size C array (a tuple).
  private func write<Characters>(_ text: String, into characters: inout Characters) {
    withUnsafeMutableBytes(of: &characters) { buffer in
      let bytes = Array(text.utf8)
      precondition(bytes.count < buffer.count)
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
  }

  // MARK: - Shares connected outside MountMate

  private func imported(_ source: String, at mountPoint: String, _ fileSystemType: String)
    throws -> NetworkShare
  {
    let mounted = try XCTUnwrap(
      MountedNetworkShare(source: source, mountPoint: mountPoint, fileSystemType: fileSystemType))
    return NetworkMountTable.importedShare(from: mounted, localize: { $0 })
  }

  func testImportedSMBShareTakesUserServerAndPath() throws {
    let share = try imported("//bob@nas.local/volume1/data", at: "/Volumes/data", "smbfs")
    XCTAssertEqual(share.server, "nas.local")
    XCTAssertEqual(share.username, "bob")
    XCTAssertEqual(share.sharePath, "volume1/data")
    XCTAssertEqual(share.name, "data")
    XCTAssertEqual(share.shareProtocol, .smb)
    // Imported shares are never auto-mounted and use the default location.
    XCTAssertFalse(share.mountAtLogin)
    XCTAssertFalse(share.keepMounted)
    XCTAssertNil(share.customMountPoint)
  }

  func testImportedSMBShareDecodesPercentEncoding() throws {
    let share = try imported("//j%40doe@nas/Family%20Photos", at: "/Volumes/Family Photos", "smbfs")
    XCTAssertEqual(share.username, "j@doe")
    XCTAssertEqual(share.sharePath, "Family Photos")
    XCTAssertEqual(share.name, "Family Photos")
  }

  func testImportedAFPShareWithoutUser() throws {
    let share = try imported("//tc.local/Data", at: "/Volumes/Data", "afpfs")
    XCTAssertEqual(share.shareProtocol, .afp)
    XCTAssertEqual(share.server, "tc.local")
    XCTAssertEqual(share.username, "")
    XCTAssertEqual(share.sharePath, "Data")
  }

  func testImportedNFSShareSplitsServerAndExport() throws {
    let share = try imported("10.0.0.5:/exports/public", at: "/Users/me/p", "nfs")
    XCTAssertEqual(share.shareProtocol, .nfs)
    XCTAssertEqual(share.server, "10.0.0.5")
    XCTAssertEqual(share.sharePath, "exports/public")
    XCTAssertEqual(share.name, "public")
    XCTAssertEqual(share.username, "")
  }

  func testImportedNFSShareWithIPv6Server() throws {
    let share = try imported("[fd00::2]:/exports/media", at: "/Users/me/m", "nfs")
    XCTAssertEqual(share.server, "fd00::2")
    XCTAssertEqual(share.sharePath, "exports/media")
  }

  func testImportedShareWithoutServerUsesFallbacks() throws {
    let smb = try imported("//", at: "/Volumes/Projects", "smbfs")
    XCTAssertEqual(smb.server, "Unknown Server")
    XCTAssertEqual(smb.sharePath, "Projects")
    XCTAssertEqual(smb.name, "Projects")

    let nfs = try imported("nas", at: "/", "nfs")
    XCTAssertEqual(nfs.server, "nas")
    XCTAssertEqual(nfs.sharePath, "Shared Folder")
  }

  func testImportedSMBShareKeepsAPort() throws {
    let share = try imported("//user@nas:8445/share", at: "/Volumes/share", "smbfs")
    XCTAssertEqual(share.server, "nas:8445")
    XCTAssertEqual(share.username, "user")
    XCTAssertEqual(share.sharePath, "share")
    XCTAssertEqual(NetworkShare.hostAndPort(fromServer: share.server).port, 8445)
  }

  func testImportedIPv6ShareWithAPortIsBracketed() throws {
    let share = try imported("//[fd00::2]:8445/share", at: "/Volumes/share", "smbfs")
    XCTAssertEqual(share.server, "[fd00::2]:8445")
    let address = NetworkShare.hostAndPort(fromServer: share.server)
    XCTAssertEqual(address.host, "fd00::2")
    XCTAssertEqual(address.port, 8445)
  }

  func testImportedIPv6ShareWithoutAPortStaysBare() throws {
    let share = try imported("//[fd00::2]/share", at: "/Volumes/share", "smbfs")
    XCTAssertEqual(share.server, "fd00::2")
  }

  func testImportedAFPShareKeepsAPort() throws {
    let share = try imported("//nas.local:5480/Media", at: "/Volumes/Media", "afpfs")
    XCTAssertEqual(share.server, "nas.local:5480")
  }

  func testImportedShareFallbacksAreLocalized() throws {
    let mounted = try XCTUnwrap(
      MountedNetworkShare(source: "//", mountPoint: "/", fileSystemType: "smbfs"))
    let share = NetworkMountTable.importedShare(from: mounted, localize: { "«\($0)»" })
    XCTAssertEqual(share.server, "«Unknown Server»")
    XCTAssertEqual(share.sharePath, "«Shared Folder»")
  }
}
