import XCTest

@testable import MountMate

final class BlockedFstabRuleTests: XCTestCase {
  // MARK: - blockedFstabEntry

  func testBlockedFstabEntryWritesNoautoRuleForVolumeUUID() {
    let entry = PersistenceManager.blockedFstabEntry(
      volumeUUID: "1234-ABCD", fileSystemType: "hfs", identifier: "DISKUUID-1234-ABCD")
    XCTAssertEqual(
      entry,
      "# MountMate block: DISKUUID-1234-ABCD\nUUID=1234-ABCD none hfs rw,noauto\n")
  }

  // MARK: - normalizedSystemVolumeUUID

  func testNormalizedSystemVolumeUUIDUppercasesValidUUIDs() {
    XCTAssertEqual(
      PersistenceManager.normalizedSystemVolumeUUID("f81d4fae-7dec-11d0-a765-00a0c91e6bf6"),
      "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6")
  }

  func testNormalizedSystemVolumeUUIDRejectsDeviceIdentifiers() {
    XCTAssertNil(PersistenceManager.normalizedSystemVolumeUUID("disk4s2"))
    XCTAssertNil(PersistenceManager.normalizedSystemVolumeUUID(""))
  }

  // MARK: - managedFstabVolumeUUIDs

  func testManagedFstabVolumeUUIDsCollectsOnlyRequestedKinds() {
    let contents = """
      # MountMate custom mount: DISK1-VOL1
      UUID=AAAA-1111 /Volumes/Backup hfs rw
      # a plain user comment
      UUID=BBBB-2222 none apfs rw
      # MountMate block: DISK2-VOL2
      UUID=CCCC-3333 none exfat rw,noauto
      """
    XCTAssertEqual(
      PersistenceManager.managedFstabVolumeUUIDs(
        kinds: [PersistenceManager.mountMateBlockPrefix], in: contents),
      ["CCCC-3333"])
  }

  // MARK: - removingManagedFstabEntries

  func testRemovalWithKindFilterKeepsOtherManagedKindsForSameVolume() {
    let contents = """
      # MountMate custom mount: DISK1-VOL1
      UUID=AAAA-1111 /Volumes/Backup hfs rw
      # MountMate block: DISK1-VOL1
      UUID=AAAA-1111 none hfs rw,noauto
      other line
      """
    let removed = PersistenceManager.removingManagedFstabEntries(
      volumeUUID: "aaaa-1111", kinds: [PersistenceManager.mountMateBlockPrefix], from: contents)
    XCTAssertEqual(
      removed,
      "# MountMate custom mount: DISK1-VOL1\nUUID=AAAA-1111 /Volumes/Backup hfs rw\nother line\n")
  }

  func testRemovalWithAllKindsRemovesEveryManagedPairForTheVolume() {
    let contents = """
      # MountMate custom mount: DISK1-VOL1
      UUID=AAAA-1111 /Volumes/Backup hfs rw
      # MountMate block: DISK1-VOL1
      UUID=AAAA-1111 none hfs rw,noauto
      """
    let removed = PersistenceManager.removingManagedFstabEntries(
      volumeUUID: "AAAA-1111",
      kinds: [PersistenceManager.mountMateFstabPrefix, PersistenceManager.mountMateBlockPrefix],
      from: contents)
    XCTAssertEqual(removed, "")
  }

  func testRemovalKeepsUnmanagedEntriesForTheSameVolume() {
    let contents = """
      UUID=AAAA-1111 none hfs rw,noauto
      # MountMate block: DISK1-VOL1
      UUID=AAAA-1111 none hfs rw,noauto
      """
    let removed = PersistenceManager.removingManagedFstabEntries(
      volumeUUID: "AAAA-1111", kinds: [PersistenceManager.mountMateBlockPrefix], from: contents)
    XCTAssertEqual(removed, "UUID=AAAA-1111 none hfs rw,noauto\n")
  }

  func testRemovalLeavesOtherVolumesUntouched() {
    let contents = """
      # MountMate block: DISK1-VOL1
      UUID=AAAA-1111 none hfs rw,noauto
      # MountMate block: DISK2-VOL2
      UUID=BBBB-2222 none exfat rw,noauto
      """
    let removed = PersistenceManager.removingManagedFstabEntries(
      volumeUUID: "AAAA-1111", kinds: [PersistenceManager.mountMateBlockPrefix], from: contents)
    XCTAssertEqual(
      removed,
      "# MountMate block: DISK2-VOL2\nUUID=BBBB-2222 none exfat rw,noauto\n")
  }

  // MARK: - hasOtherFstabEntry

  func testHasOtherFstabEntryIgnoresOwnBlockRules() {
    let contents = """
      # MountMate block: DISK1-VOL1
      UUID=AAAA-1111 none hfs rw,noauto
      """
    XCTAssertFalse(PersistenceManager.hasOtherFstabEntry(volumeUUID: "AAAA-1111", in: contents))
  }

  func testHasOtherFstabEntryDetectsCustomMountAndUserLines() {
    let customMount = """
      # MountMate custom mount: DISK1-VOL1
      UUID=AAAA-1111 /Volumes/Backup hfs rw
      """
    XCTAssertTrue(
      PersistenceManager.hasOtherFstabEntry(volumeUUID: "aaaa-1111", in: customMount))

    let userLine = "UUID=BBBB-2222 none apfs rw,noauto\n"
    XCTAssertTrue(PersistenceManager.hasOtherFstabEntry(volumeUUID: "BBBB-2222", in: userLine))
    XCTAssertFalse(PersistenceManager.hasOtherFstabEntry(volumeUUID: "CCCC-3333", in: userLine))
  }

  func testHasOtherFstabEntryIgnoresCommentedLines() {
    let contents = "# UUID=AAAA-1111 none hfs rw,noauto\n"
    XCTAssertFalse(PersistenceManager.hasOtherFstabEntry(volumeUUID: "AAAA-1111", in: contents))
  }

  // MARK: - fstabFileSystemType

  func testFstabFileSystemTypePrefersPlistFilesystemType() {
    XCTAssertEqual(
      PersistenceManager.fstabFileSystemType(
        plist: ["FilesystemName": "Mac OS Extended (Journaled)", "FilesystemType": "hfs"],
        fallback: nil),
      "hfs")
  }

  func testFstabFileSystemTypeFallsBackToRawValue() {
    XCTAssertEqual(
      PersistenceManager.fstabFileSystemType(plist: nil, fallback: "ExFAT"), "exfat")
  }

  func testFstabFileSystemTypeIsNilWithoutAnyCandidate() {
    XCTAssertNil(PersistenceManager.fstabFileSystemType(plist: nil, fallback: nil))
  }

  // MARK: - startupBlockEligibility

  private func eligibility(
    _ plist: [String: Any], boot: String? = "disk3", roles: [String]? = []
  ) -> PersistenceManager.StartupBlockEligibility {
    PersistenceManager.startupBlockEligibility(
      plist: plist, bootAPFSContainer: boot, apfsRoles: roles)
  }

  func testExternalAPFSVolumeIsEligible() {
    XCTAssertEqual(
      eligibility([
        "FilesystemType": "apfs", "APFSContainerReference": "disk5",
        "MountPoint": "/Volumes/Backup",
      ]),
      .eligible(fileSystemType: "apfs"))
  }

  func testTimeMachineBackupRoleIsEligible() {
    XCTAssertEqual(
      eligibility(
        ["FilesystemType": "apfs", "APFSContainerReference": "disk5"], roles: ["Backup"]),
      .eligible(fileSystemType: "apfs"))
  }

  func testNativeNonAPFSTypesAreEligible() {
    for type in ["hfs", "exfat", "msdos"] {
      XCTAssertEqual(
        eligibility(["FilesystemType": type, "MountPoint": ""], roles: nil),
        .eligible(fileSystemType: type), type)
    }
  }

  func testRootAndSystemMountPointsAreNeverEligible() {
    for mountPoint in ["/", "/System/Volumes/Data", "/System/Volumes/iSCPreboot"] {
      guard
        case .ineligible = eligibility(
          ["FilesystemType": "apfs", "APFSContainerReference": "disk9", "MountPoint": mountPoint])
      else { return XCTFail(mountPoint) }
    }
  }

  func testVolumesInBootContainerAreNeverEligible() {
    guard
      case .ineligible = eligibility(
        ["FilesystemType": "apfs", "APFSContainerReference": "disk3", "MountPoint": ""])
    else { return XCTFail() }
  }

  func testSystemRolesAreNeverEligible() {
    for role in ["System", "Data", "Preboot", "Recovery", "VM", "Update", "xART", "Hardware"] {
      guard
        case .ineligible = eligibility(
          ["FilesystemType": "apfs", "APFSContainerReference": "disk1"], roles: [role])
      else { return XCTFail(role) }
    }
  }

  func testAPFSWithUnknownRolesIsNotEligible() {
    guard
      case .ineligible = eligibility(
        ["FilesystemType": "apfs", "APFSContainerReference": "disk5"], roles: nil)
    else { return XCTFail() }
  }

  func testThirdPartyDriversAreNotEligible() {
    // NTFS too: `rw` in fstab would enable Apple's experimental NTFS writes.
    for type in ["ntfs", "ufsd_NTFS", "tuxera_ntfs", "macfuse", ""] {
      guard case .ineligible = eligibility(["FilesystemType": type], roles: nil)
      else { return XCTFail(type) }
    }
    guard case .ineligible = eligibility([:], roles: nil) else { return XCTFail() }
  }

  func testAPFSIsNotEligibleWhenBootContainerIsUnknown() {
    guard
      case .ineligible = eligibility(
        ["FilesystemType": "apfs", "APFSContainerReference": "disk5"], boot: nil)
    else { return XCTFail() }
  }

  // MARK: - Orphaned / hand-edited comments

  func testIsBlockRuleLine() {
    XCTAssertTrue(PersistenceManager.isBlockRuleLine("UUID=AAAA-1111 none hfs rw,noauto"))
    XCTAssertTrue(PersistenceManager.isBlockRuleLine("  UUID=AAAA-1111\tnone apfs noauto,rw"))
    XCTAssertFalse(PersistenceManager.isBlockRuleLine("UUID=AAAA-1111 /Volumes/X hfs rw"))
    XCTAssertFalse(PersistenceManager.isBlockRuleLine("UUID=AAAA-1111 none hfs rw"))
    XCTAssertFalse(PersistenceManager.isBlockRuleLine("# MountMate block: X"))
    XCTAssertFalse(PersistenceManager.isBlockRuleLine(""))
  }

  func testOrphanedBlockCommentDoesNotClaimTheUsersNextLine() {
    // The rule line under the comment was deleted by hand; the next line is
    // the user's own entry and must not be treated as MountMate's.
    let contents = """
      # MountMate block: DISK1-VOL1
      UUID=BBBB-2222 /Volumes/Work apfs rw
      """
    XCTAssertEqual(
      PersistenceManager.managedFstabVolumeUUIDs(
        kinds: [PersistenceManager.mountMateBlockPrefix], in: contents),
      [])
    XCTAssertEqual(
      PersistenceManager.removingManagedFstabEntries(
        volumeUUID: "BBBB-2222", kinds: [PersistenceManager.mountMateBlockPrefix],
        from: contents),
      contents + "\n")
    XCTAssertTrue(PersistenceManager.hasOtherFstabEntry(volumeUUID: "BBBB-2222", in: contents))
  }
}
