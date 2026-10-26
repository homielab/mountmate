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
}
