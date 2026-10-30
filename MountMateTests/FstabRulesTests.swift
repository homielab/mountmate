//  Created by homielab.com

import XCTest

@testable import MountMate

/// The custom mount point rule and the startup-block diff, which end up in
/// a root-written /etc/fstab.
final class FstabRulesTests: XCTestCase {
  private let uuid = "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"
  private let otherUUID = "0E2B5C1A-3D4F-4A5B-8C6D-7E8F9A0B1C2D"
  private var identifier: String { "DISK-\(uuid)" }

  private func customEntry(
    _ mountPoint: String, contents: String = "", fileSystemType: String = "hfs"
  ) throws -> String {
    try FstabRules.updatedFstabContents(
      from: contents, volumeUUID: uuid, identifier: identifier, mountPoint: mountPoint,
      fileSystemType: fileSystemType)
  }

  private func errorCode(_ body: () throws -> Void) -> Int? {
    do {
      try body()
      return nil
    } catch {
      return (error as NSError).code
    }
  }

  // MARK: - updatedFstabContents

  func testCustomEntryInEmptyFileIsCommentPlusRule() throws {
    XCTAssertEqual(
      try customEntry("/Volumes/Backup"),
      "# MountMate custom mount: \(identifier)\nUUID=\(uuid) /Volumes/Backup hfs rw\n")
  }

  func testCustomEntryEscapesSpacesTabsAndBackslashesInMountPoint() throws {
    XCTAssertEqual(
      try customEntry("/Users/me/My Disk\tA\\B"),
      "# MountMate custom mount: \(identifier)\n"
        + "UUID=\(uuid) /Users/me/My\\040Disk\\011A\\\\B hfs rw\n")
  }

  func testCustomEntryIsAppendedAfterUserLinesWithTrailingBlankLinesTrimmed() throws {
    let contents = "# user comment\nUUID=\(otherUUID) none apfs rw,noauto\n\n\n"
    XCTAssertEqual(
      try customEntry("/Volumes/Backup", contents: contents),
      "# user comment\nUUID=\(otherUUID) none apfs rw,noauto\n\n"
        + "# MountMate custom mount: \(identifier)\nUUID=\(uuid) /Volumes/Backup hfs rw\n")
  }

  func testCustomEntryIsIdempotent() throws {
    let contents = "UUID=\(otherUUID) /Volumes/Other exfat rw\n"
    let once = try customEntry("/Volumes/My Backup", contents: contents)
    let twice = try customEntry("/Volumes/My Backup", contents: once)
    XCTAssertEqual(twice, once)
  }

  func testCustomEntryReplacesPreviousMountPointOfTheSameVolume() throws {
    let first = try customEntry("/Volumes/Old")
    let second = try customEntry("/Volumes/New", contents: first)
    XCTAssertEqual(
      second, "# MountMate custom mount: \(identifier)\nUUID=\(uuid) /Volumes/New hfs rw\n")
  }

  func testCustomEntryReplacesOldEntryWrittenWithLowercaseUUID() throws {
    let old = "# MountMate custom mount: OLD-ID\nUUID=\(uuid.lowercased()) /Volumes/Old hfs rw\n"
    XCTAssertEqual(
      try customEntry("/Volumes/New", contents: old),
      "# MountMate custom mount: \(identifier)\nUUID=\(uuid) /Volumes/New hfs rw\n")
  }

  func testCustomEntryConflictsWithUserRuleForTheSameVolume() {
    let contents = "UUID=\(uuid) /mnt/disk hfs rw\n"
    XCTAssertEqual(errorCode { _ = try customEntry("/Volumes/Backup", contents: contents) }, 1)
  }

  func testCustomEntryConflictsWithStartupBlockRuleForTheSameVolume() {
    let block = FstabRules.blockedFstabEntry(
      volumeUUID: uuid, fileSystemType: "hfs", identifier: identifier)!
    XCTAssertEqual(errorCode { _ = try customEntry("/Volumes/Backup", contents: block) }, 1)
  }

  func testCustomEntryIgnoresCommentedRulesAndOtherVolumes() throws {
    let contents = "#UUID=\(uuid) /mnt/disk hfs rw\nUUID=\(uuid)0 /mnt/x hfs rw\n"
    XCTAssertNoThrow(try customEntry("/Volumes/Backup", contents: contents))
  }

  func testCustomEntryRejectsUnsafeFieldsBeforeWritingAnything() {
    let invalid = FstabRules.fstabInvalidFieldErrorCode
    XCTAssertEqual(errorCode { _ = try customEntry("/Volumes/A\nUUID=X / hfs rw") }, invalid)
    XCTAssertEqual(
      errorCode {
        _ = try FstabRules.updatedFstabContents(
          from: "", volumeUUID: self.uuid, identifier: "ID\n# injected", mountPoint: "/Volumes/A",
          fileSystemType: "hfs")
      }, invalid)
    XCTAssertEqual(
      errorCode {
        _ = try FstabRules.updatedFstabContents(
          from: "", volumeUUID: "{\(self.uuid)}", identifier: self.identifier,
          mountPoint: "/Volumes/A", fileSystemType: "hfs")
      }, invalid)
    XCTAssertEqual(
      errorCode { _ = try customEntry("/Volumes/A", fileSystemType: "hfs rw,x") }, invalid)
  }

  // MARK: - removingCustomMountEntry

  func testRemovingCustomEntryKeepsStartupBlockAndUserLines() throws {
    let block = FstabRules.blockedFstabEntry(
      volumeUUID: otherUUID, fileSystemType: "apfs", identifier: "DISK-\(otherUUID)")!
    let contents = try customEntry("/Volumes/Backup", contents: "# user\n" + block)
    XCTAssertEqual(
      FstabRules.removingCustomMountEntry(volumeUUID: uuid.lowercased(), from: contents),
      "# user\n" + block)
  }

  func testRemovingCustomEntryRoundTripsToTheOriginalFile() throws {
    let original = "UUID=\(otherUUID) /Volumes/Other exfat rw\n"
    let withEntry = try customEntry("/Volumes/Backup", contents: original)
    XCTAssertEqual(
      FstabRules.removingCustomMountEntry(volumeUUID: uuid, from: withEntry), original)
  }

  // MARK: - isConflictingFstabEntry / fstabEscapedField

  func testIsConflictingFstabEntryNeedsExactUUIDFollowedByWhitespace() {
    XCTAssertTrue(
      FstabRules.isConflictingFstabEntry("  UUID=\(uuid)\t/mnt hfs rw", volumeUUID: uuid))
    XCTAssertFalse(FstabRules.isConflictingFstabEntry("UUID=\(uuid)", volumeUUID: uuid))
    XCTAssertFalse(
      FstabRules.isConflictingFstabEntry("UUID=\(uuid)X /mnt hfs rw", volumeUUID: uuid))
    XCTAssertFalse(
      FstabRules.isConflictingFstabEntry("# UUID=\(uuid) /mnt hfs rw", volumeUUID: uuid))
    XCTAssertFalse(FstabRules.isConflictingFstabEntry("", volumeUUID: uuid))
  }

  func testFstabEscapedFieldEscapesBackslashFirst() {
    XCTAssertEqual(FstabRules.fstabEscapedField("a\\040b"), "a\\\\040b")
    XCTAssertEqual(FstabRules.fstabEscapedField("plain"), "plain")
  }

  // MARK: - startupBlockDiff / applyingStartupBlockChanges

  private func info(_ volumeUUID: String, name: String = "Disk") -> ManagedVolumeInfo {
    ManagedVolumeInfo(volumeUUID: volumeUUID, diskUUID: "DISK", name: name)
  }

  func testStartupBlockDiffSplitsPresentStaleMissingAndAlreadyAddressed() {
    let third = "11111111-2222-3333-4444-555555555555"
    let contents =
      FstabRules.blockedFstabEntry(
        volumeUUID: otherUUID, fileSystemType: "apfs", identifier: "DISK-\(otherUUID)")!
      + "UUID=\(third) /mnt/x hfs rw\n"
    let diff = FstabRules.startupBlockDiff(
      enabled: true,
      blockedInfos: [info(uuid.lowercased()), info(third), info("disk4s2")],
      contents: contents)

    XCTAssertEqual(diff.present, [otherUUID])
    XCTAssertEqual(diff.stale, [otherUUID])
    XCTAssertEqual(diff.missing.map(\.uuid), [uuid])
    XCTAssertEqual(diff.alreadyHasEntry.map(\.volumeUUID), [third])
  }

  func testStartupBlockDiffWhenDisabledMarksEveryRuleStale() {
    let contents = FstabRules.blockedFstabEntry(
      volumeUUID: uuid, fileSystemType: "hfs", identifier: identifier)!
    let diff = FstabRules.startupBlockDiff(
      enabled: false, blockedInfos: [info(uuid)], contents: contents)
    XCTAssertEqual(diff.stale, [uuid])
    XCTAssertTrue(diff.missing.isEmpty)
  }

  func testApplyingStartupBlockChangesRemovesStaleAddsSortedAndSkipsUnsafe() {
    let contents =
      "# user\n"
      + FstabRules.blockedFstabEntry(
        volumeUUID: uuid, fileSystemType: "hfs", identifier: identifier)!
    let safe = FstabRules.StartupBlockAddition(
      uuid: otherUUID, fileSystemType: "apfs", info: info(otherUUID))
    let unsafe = FstabRules.StartupBlockAddition(
      uuid: "11111111-2222-3333-4444-555555555555", fileSystemType: "ntfs rw",
      info: info("11111111-2222-3333-4444-555555555555"))

    let result = FstabRules.applyingStartupBlockChanges(
      to: contents, removing: [uuid], adding: [unsafe, safe])

    XCTAssertEqual(
      result.contents,
      "# user\n"
        + FstabRules.blockedFstabEntry(
          volumeUUID: otherUUID, fileSystemType: "apfs", identifier: "DISK-\(otherUUID)")!)
    XCTAssertEqual(result.skipped.map(\.uuid), [unsafe.uuid])
  }

  // MARK: - Custom mount point file systems

  private func customFileSystem(
    _ plist: [String: Any]?, fallback: String? = nil
  ) -> FstabRules.CustomMountPointFileSystem {
    FstabRules.customMountPointFileSystem(plist: plist, fallback: fallback)
  }

  func testBuiltInFileSystemsMayGetACustomMountPoint() {
    for type in ["apfs", "hfs", "exfat", "msdos"] {
      XCTAssertEqual(customFileSystem(["FilesystemType": type]), .supported(type))
    }
    XCTAssertEqual(customFileSystem(["FilesystemType": "APFS"]), .supported("apfs"))
  }

  func testNTFSAndThirdPartyNTFSDriversAreRefusedAsNTFS() {
    for type in ["ntfs", "ufsd_NTFS", "tuxera_ntfs"] {
      XCTAssertEqual(
        customFileSystem(["FilesystemType": type, "FilesystemName": "Some Driver"]),
        .unsupported(name: "NTFS"), type)
    }
  }

  func testOtherDriversAreRefusedByTheirName() {
    XCTAssertEqual(
      customFileSystem(["FilesystemType": "fuse_ext4", "FilesystemName": "ext4"]),
      .unsupported(name: "ext4"))
    XCTAssertEqual(customFileSystem(["FilesystemType": "macfuse"]), .unsupported(name: "macfuse"))
  }

  func testRawTypeDecidesOverTheMappedOne() {
    // "ufsd_hfs" would map to "hfs", but a third-party driver mounts it.
    XCTAssertEqual(customFileSystem(["FilesystemType": "ufsd_hfs"]), .unsupported(name: "ufsd_hfs"))
  }

  func testFallbackWithoutDiskutilInfo() {
    XCTAssertEqual(customFileSystem(nil, fallback: "Apple_HFS"), .supported("hfs"))
    XCTAssertEqual(customFileSystem(nil, fallback: "Windows_NTFS"), .unsupported(name: "NTFS"))
    XCTAssertEqual(customFileSystem(nil, fallback: nil), .unknown)
  }

  func testRuleIsNeverBuiltForAnUnsupportedType() {
    for type in ["ntfs", "ufsdntfs", "tuxerantfs", "macfuse"] {
      XCTAssertEqual(
        errorCode { _ = try customEntry("/Volumes/A", fileSystemType: type) },
        FstabRules.fstabUnsupportedFileSystemErrorCode, type)
    }
  }

  func testKnownUnsupportedFileSystemForTheMenu() {
    typealias Rules = FstabRules
    XCTAssertEqual(
      Rules.knownUnsupportedCustomMountPointFileSystem(
        contentType: "Windows_NTFS", mountedType: nil),
      "NTFS")
    XCTAssertEqual(
      Rules.knownUnsupportedCustomMountPointFileSystem(
        contentType: "Microsoft Basic Data", mountedType: "ufsd_NTFS"), "NTFS")
    XCTAssertEqual(
      Rules.knownUnsupportedCustomMountPointFileSystem(
        contentType: "Microsoft Basic Data", mountedType: "tuxera_ntfs"), "NTFS")
    XCTAssertEqual(
      Rules.knownUnsupportedCustomMountPointFileSystem(
        contentType: "Microsoft Basic Data", mountedType: "macfuse"), "macfuse")
    // Unknown until diskutil is asked: applyCustomMountPoint decides.
    XCTAssertNil(
      Rules.knownUnsupportedCustomMountPointFileSystem(
        contentType: "Microsoft Basic Data", mountedType: nil))
    XCTAssertNil(
      Rules.knownUnsupportedCustomMountPointFileSystem(
        contentType: "Microsoft Basic Data", mountedType: "exfat"))
    XCTAssertNil(
      Rules.knownUnsupportedCustomMountPointFileSystem(
        contentType: "Apple_APFS", mountedType: "apfs"))
  }

  func testRefusalMessageNamesTheFileSystem() {
    XCTAssertTrue(FstabRules.unsupportedFileSystemMessage(name: "NTFS").contains("NTFS"))
  }

  func testIsConflictingFstabEntryIgnoresUUIDCase() {
    let lower = uuid.lowercased()
    XCTAssertTrue(FstabRules.isConflictingFstabEntry("UUID=\(lower) /mnt hfs rw", volumeUUID: uuid))
    XCTAssertTrue(
      FstabRules.isConflictingFstabEntry("\tUUID=\(lower)\t/mnt\thfs\trw", volumeUUID: uuid))
    XCTAssertTrue(FstabRules.isConflictingFstabEntry("UUID=\(uuid) /mnt hfs rw", volumeUUID: lower))
    XCTAssertFalse(
      FstabRules.isConflictingFstabEntry("#UUID=\(lower) /mnt hfs rw", volumeUUID: uuid))
    XCTAssertFalse(
      FstabRules.isConflictingFstabEntry("UUID=\(lower)0 /mnt hfs rw", volumeUUID: uuid))
  }

  func testHandWrittenLowercaseRuleBlocksASecondRule() {
    let contents = "UUID=\(uuid.lowercased())\t/Volumes/Mine\thfs\trw\n"
    XCTAssertEqual(errorCode { _ = try customEntry("/Volumes/Backup", contents: contents) }, 1)
  }

  // MARK: - Custom mount rules already in /etc/fstab

  func testCustomMountRulesAreParsedWithTheirFields() {
    let contents = """
      # MountMate custom mount: DISK-\(uuid)
      UUID=\(uuid) /Volumes/My\\040Disk ntfs rw
      # MountMate block: X-\(otherUUID)
      UUID=\(otherUUID) none apfs rw,noauto
      """
    XCTAssertEqual(
      FstabRules.customMountRules(in: contents),
      [
        FstabRules.CustomMountRule(
          identifier: "DISK-\(uuid)", volumeUUID: uuid, mountPoint: "/Volumes/My Disk",
          fileSystemType: "ntfs")
      ])
  }

  func testOnlyRulesOfRefusedFileSystemsAreUnsupported() {
    let contents = """
      UUID=\(otherUUID) /Volumes/Hand ntfs rw
      # MountMate custom mount: A
      UUID=\(uuid) /Volumes/A ntfs rw
      # MountMate custom mount: B
      UUID=\(otherUUID) /Volumes/B apfs rw
      # MountMate custom mount: orphaned comment
      LABEL=Foo /Volumes/C ntfs rw
      """
    XCTAssertEqual(
      FstabRules.unsupportedCustomMountRules(in: contents).map(\.identifier), ["A"],
      "hand-written lines, allowed types and comments without a UUID rule are left alone")
  }

  func testUnescapingReversesEscaping() {
    for value in ["/Volumes/A B", "/Volumes/A\tB", "/Volumes/A\\040B", "/Volumes/A\\"] {
      XCTAssertEqual(
        FstabRules.fstabUnescapedField(FstabRules.fstabEscapedField(value)), value)
    }
  }

  func testRulesWithoutASavedEntryAreUntracked() {
    let contents = """
      # MountMate custom mount: A
      UUID=\(uuid) /Volumes/A apfs rw
      # MountMate custom mount: B
      UUID=\(otherUUID) /Volumes/B ntfs rw
      # MountMate custom mount: C
      UUID=\(otherUUID) /Volumes/C exfat rw
      UUID=\(uuid) /Volumes/Hand apfs rw
      """
    let rules = FstabRules.customMountRules(in: contents)
    XCTAssertEqual(
      FstabRules.untrackedCustomMountRules(rules, savedEntries: []).map(\.identifier), ["A", "C"],
      "unsupported rules are listed elsewhere; hand-written lines are not MountMate's")

    let savedByID = VolumeCustomMountPoint(
      volumeUUID: "1A2B3C4D-0000-0000-0000-000000000000", backingDiskIdentifier: "X",
      name: "A", mountPoint: "/Volumes/A")
    XCTAssertEqual(
      FstabRules.untrackedCustomMountRules(
        [
          FstabRules.CustomMountRule(
            identifier: savedByID.id, volumeUUID: uuid, mountPoint: "/Volumes/A",
            fileSystemType: "apfs")
        ],
        savedEntries: [savedByID]), [])

    let savedByUUID = VolumeCustomMountPoint(
      volumeUUID: otherUUID.lowercased(), backingDiskIdentifier: "disk4s1", name: "C",
      mountPoint: "/Volumes/C")
    XCTAssertEqual(
      FstabRules.untrackedCustomMountRules(rules, savedEntries: [savedByUUID]).map(\.identifier),
      ["A"], "an entry saved under another disk identifier still tracks its volume's rule")
  }

  // MARK: - CRLF files

  private let crlfFstab =
    "# hand-written\r\nUUID=11111111-1111-1111-1111-111111111111 none apfs rw,noauto\r\n"
    + "# MountMate custom mount: disk5s1\r\n"
    + "UUID=22222222-2222-2222-2222-222222222222 /Users/me/Backup apfs rw\r\n"

  func testCRLFLinesAreNotSplitInTwo() {
    XCTAssertEqual(FstabRules.fstabLines(crlfFstab).count, 5)
    XCTAssertEqual(FstabRules.fstabLines("a\rb\nc").count, 3)
    XCTAssertEqual(FstabRules.customMountRules(in: crlfFstab).count, 1)
  }

  func testUnchangedCRLFFileComparesEqualAndIsNotRewritten() {
    XCTAssertEqual(
      FstabRules.removingCustomMountEntry(
        volumeUUID: "33333333-3333-3333-3333-333333333333", from: crlfFstab), crlfFstab)
    XCTAssertEqual(FstabRules.trimmedFstabContents(crlfFstab), crlfFstab)
  }

  func testEditedCRLFFileKeepsCRLF() {
    let removed = FstabRules.removingCustomMountEntry(
      volumeUUID: "22222222-2222-2222-2222-222222222222", from: crlfFstab)
    XCTAssertEqual(
      removed,
      "# hand-written\r\nUUID=11111111-1111-1111-1111-111111111111 none apfs rw,noauto\r\n")
  }
}
