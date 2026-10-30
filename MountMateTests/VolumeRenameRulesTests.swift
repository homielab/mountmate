//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeRenameRulesTests: XCTestCase {
  func testEmptyOrBlankNameIsRejected() {
    XCTAssertEqual(VolumeRenameRules.problem(with: "", fileSystemType: "APFS"), .empty)
    XCTAssertEqual(VolumeRenameRules.problem(with: "   ", fileSystemType: "APFS"), .empty)
  }

  func testSlashColonAndControlCharactersAreRejected() {
    for name in ["Back/up", "Back:up", "Line\nBreak", "Tab\tName"] {
      XCTAssertEqual(
        VolumeRenameRules.problem(with: name, fileSystemType: "APFS"), .forbiddenCharacter, name)
    }
  }

  func testValidNamesAreAccepted() {
    for name in ["Backup", "My Disk 2", "Ảnh gia đình", "照片", " Padded "] {
      XCTAssertNil(VolumeRenameRules.problem(with: name, fileSystemType: "APFS"), name)
    }
  }

  func testLengthLimitDependsOnTheFileSystem() {
    XCTAssertEqual(VolumeRenameRules.maxLength(fileSystemType: "APFS"), 255)
    XCTAssertEqual(VolumeRenameRules.maxLength(fileSystemType: "Apple_HFS"), 255)
    XCTAssertEqual(VolumeRenameRules.maxLength(fileSystemType: nil), 255)
    XCTAssertEqual(VolumeRenameRules.maxLength(fileSystemType: "ExFAT"), 15)
    XCTAssertEqual(VolumeRenameRules.maxLength(fileSystemType: "MS-DOS FAT32"), 11)
    XCTAssertEqual(VolumeRenameRules.maxLength(fileSystemType: "Microsoft Basic Data"), 255)

    XCTAssertNil(VolumeRenameRules.problem(with: "ABCDEFGHIJK", fileSystemType: "MS-DOS FAT32"))
    XCTAssertEqual(
      VolumeRenameRules.problem(with: "ABCDEFGHIJKL", fileSystemType: "MS-DOS FAT32"),
      .tooLong(maxLength: 11))
    XCTAssertNil(VolumeRenameRules.problem(with: "Photos Backup", fileSystemType: "ExFAT"))
    XCTAssertNil(VolumeRenameRules.problem(with: "ABCDEFGHIJKLMNO", fileSystemType: "ExFAT"))
    XCTAssertEqual(
      VolumeRenameRules.problem(with: "ABCDEFGHIJKLMNOP", fileSystemType: "ExFAT"),
      .tooLong(maxLength: 15))
    XCTAssertNil(
      VolumeRenameRules.problem(with: String(repeating: "a", count: 255), fileSystemType: "APFS"))
    XCTAssertEqual(
      VolumeRenameRules.problem(with: String(repeating: "a", count: 256), fileSystemType: "APFS"),
      .tooLong(maxLength: 255))
  }

  func testProblemMessagesAreNotEmpty() {
    XCTAssertFalse(VolumeRenameRules.message(for: .empty).isEmpty)
    XCTAssertFalse(VolumeRenameRules.message(for: .forbiddenCharacter).isEmpty)
    XCTAssertTrue(VolumeRenameRules.message(for: .tooLong(maxLength: 11)).contains("11"))
  }

  func testArgumentsRenameTheDeviceWithTheTrimmedName() {
    XCTAssertEqual(
      VolumeRenameRules.arguments(forDevice: "disk4s2", newName: "  Photo Backup "),
      ["rename", "disk4s2", "Photo Backup"])
  }

  func testUnchangedNameIsNotAChange() {
    XCTAssertFalse(VolumeRenameRules.isChange("Backup ", from: "Backup"))
    XCTAssertTrue(VolumeRenameRules.isChange("Backup 2", from: "Backup"))
  }

  func testBusyFailureSaysTheVolumeIsInUse() {
    let result = ProcessResult(
      stdout: "", stderr: "Volume is busy", exitCode: 1, timedOut: false)
    let failure = VolumeRenameRules.failure(for: result, volumeName: "Backup")
    XCTAssertTrue(failure.message.contains("Backup"))
    XCTAssertTrue(failure.message.contains("Volume is busy"))
    XCTAssertEqual(
      failure.message.components(separatedBy: "\n\n").first,
      String(
        format: NSLocalizedString(
          "Failed to rename “%@” because it is currently in use by another application.",
          comment: "Rename Volume error message"), "Backup"))
  }

  func testOtherFailureMentionsUnsupportedFileSystemAndDetails() {
    let result = ProcessResult(
      stdout: "", stderr: "Error: -69886: Unable to rename", exitCode: 1, timedOut: false)
    let failure = VolumeRenameRules.failure(for: result, volumeName: "NTFS Disk")
    XCTAssertEqual(failure.title, NSLocalizedString("Rename Failed", comment: "Alert title"))
    XCTAssertTrue(failure.message.contains("NTFS Disk"))
    XCTAssertTrue(failure.message.hasSuffix("Error: -69886: Unable to rename"))
    XCTAssertFalse(failure.message.hasPrefix("Failed to rename"))
  }

  private func volume(fileSystemType: String?, mounted: String?) -> Volume {
    var volume = Volume(
      id: "v", deviceIdentifier: "disk9s2", diskUUID: nil, name: "USB",
      isMounted: mounted != nil, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: fileSystemType, usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
    volume.mountedFileSystemType = mounted
    return volume
  }

  func testMountedTypeWinsOverVaguePartitionContent() {
    let fat = volume(fileSystemType: "Microsoft Basic Data", mounted: "msdos")
    let exfat = volume(fileSystemType: "Microsoft Basic Data", mounted: "exfat")
    let ntfs = volume(fileSystemType: "Microsoft Basic Data", mounted: "ntfs")
    let unmounted = volume(fileSystemType: "Microsoft Basic Data", mounted: nil)
    func limit(_ v: Volume) -> Int {
      VolumeRenameRules.maxLength(fileSystemType: VolumeRenameRules.effectiveFileSystemType(of: v))
    }
    XCTAssertEqual(limit(fat), 11)
    XCTAssertEqual(limit(exfat), 15)
    XCTAssertEqual(limit(ntfs), 255)
    XCTAssertEqual(limit(unmounted), 255)
    XCTAssertEqual(
      VolumeRenameRules.problem(
        with: "ABCDEFGHIJKL", fileSystemType: VolumeRenameRules.effectiveFileSystemType(of: fat)),
      .tooLong(maxLength: 11))
  }

  func testNonASCIINamesAreRejectedOnFATOnly() {
    XCTAssertEqual(VolumeRenameRules.problem(with: "Ảnh", fileSystemType: "msdos"), .nonASCII)
    XCTAssertEqual(
      VolumeRenameRules.problem(with: "Café", fileSystemType: "MS-DOS FAT32"), .nonASCII)
    XCTAssertNil(VolumeRenameRules.problem(with: "Ảnh", fileSystemType: "exfat"))
    XCTAssertNil(VolumeRenameRules.problem(with: "Ảnh", fileSystemType: "APFS"))
    XCTAssertFalse(VolumeRenameRules.message(for: .nonASCII).isEmpty)
  }
}
