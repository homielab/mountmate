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

  func testRemovalWithoutKindFilterRemovesEveryManagedPairForTheVolume() {
    let contents = """
      # MountMate custom mount: DISK1-VOL1
      UUID=AAAA-1111 /Volumes/Backup hfs rw
      # MountMate block: DISK1-VOL1
      UUID=AAAA-1111 none hfs rw,noauto
      """
    let removed = PersistenceManager.removingManagedFstabEntries(
      volumeUUID: "AAAA-1111", kinds: nil, from: contents)
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
}
