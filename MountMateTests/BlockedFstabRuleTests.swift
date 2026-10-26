import XCTest

@testable import MountMate

final class BlockedFstabRuleTests: XCTestCase {
  // MARK: - blockedFstabEntry

  func testBlockedFstabEntryWritesNoautoRuleForVolumeUUID() {
    let entry = PersistenceManager.blockedFstabEntry(
      volumeUUID: "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6", fileSystemType: "hfs",
      identifier: "DISKUUID-F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6")
    XCTAssertEqual(
      entry,
      "# MountMate block: DISKUUID-F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6\n"
        + "UUID=F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6 none hfs rw,noauto\n")
  }

  func testBlockedFstabEntryAllowsPrintableUnicodeIdentifier() {
    let entry = PersistenceManager.blockedFstabEntry(
      volumeUUID: "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6", fileSystemType: "apfs",
      identifier: "DISKUUID-Bản sao #1")
    XCTAssertNotNil(entry)
    XCTAssertTrue(entry!.contains("# MountMate block: DISKUUID-Bản sao #1\n"))
  }

  func testBlockedFstabEntryRejectsNewlineInIdentifier() {
    XCTAssertNil(
      PersistenceManager.blockedFstabEntry(
        volumeUUID: "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6", fileSystemType: "apfs",
        identifier: "DISKUUID\nUUID=11111111-2222-4333-8444-555555555555 none apfs rw"))
  }

  func testBlockedFstabEntryRejectsNonStrictUUIDs() {
    for uuid in [
      "1234-ABCD", "{F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6}",
      "F81D4FAE7DEC11D0A76500A0C91E6BF6", "F81D4FAE-7DEC-11D0-A765", "NONE", "",
    ] {
      XCTAssertNil(
        PersistenceManager.blockedFstabEntry(
          volumeUUID: uuid, fileSystemType: "apfs", identifier: "DISKUUID-VOLUUID"),
        uuid)
    }
  }

  func testBlockedFstabEntryRejectsUnsafeFileSystemType() {
    for type in ["APFS", "ap fs", "apfs\nrw", "apfs#", ""] {
      XCTAssertNil(
        PersistenceManager.blockedFstabEntry(
          volumeUUID: "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6", fileSystemType: type,
          identifier: "DISKUUID-VOLUUID"),
        type)
    }
  }

  // MARK: - Rule field validation

  func testContainsUnsafeFstabCharacterRejectsControlCharacters() {
    for value in ["a\nb", "\n", "\r", "a\u{2028}b", "a\u{0}b"] {
      XCTAssertTrue(PersistenceManager.containsUnsafeFstabCharacter(value), value.debugDescription)
    }
  }

  func testContainsUnsafeFstabCharacterAllowsPrintableFields() {
    for value in [" ", "\t", "a#b", "/Volumes/Bản sao", "disk4s1", "🎉", ""] {
      XCTAssertFalse(PersistenceManager.containsUnsafeFstabCharacter(value), value.debugDescription)
    }
  }

  func testIsStrictFstabUUIDAcceptsOnlyHyphenatedHexForms() {
    XCTAssertTrue(PersistenceManager.isStrictFstabUUID("F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"))
    XCTAssertTrue(PersistenceManager.isStrictFstabUUID("f81d4fae-7dec-11d0-a765-00a0c91e6bf6"))
    XCTAssertFalse(PersistenceManager.isStrictFstabUUID("f81d4fae-7dec-11d0-a765-00a0c91e6bf"))
    XCTAssertFalse(
      PersistenceManager.isStrictFstabUUID("{F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6}"))
    XCTAssertFalse(
      PersistenceManager.isStrictFstabUUID("urn:uuid:F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"))
    XCTAssertFalse(PersistenceManager.isStrictFstabUUID("1234-ABCD"))
    XCTAssertFalse(PersistenceManager.isStrictFstabUUID(""))
  }

  func testIsPlainFstabFileSystemType() {
    XCTAssertTrue(PersistenceManager.isPlainFstabFileSystemType("apfs"))
    XCTAssertTrue(PersistenceManager.isPlainFstabFileSystemType("msdos"))
    XCTAssertFalse(PersistenceManager.isPlainFstabFileSystemType("APFS"))
    XCTAssertFalse(PersistenceManager.isPlainFstabFileSystemType("ap fs"))
    XCTAssertFalse(PersistenceManager.isPlainFstabFileSystemType("apfs\n"))
    XCTAssertFalse(PersistenceManager.isPlainFstabFileSystemType(""))
  }

  // MARK: - Staged file integrity

  private func runShell(_ command: String) -> (exitCode: Int32, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = Pipe()
    try? process.run()
    process.waitUntilExit()
    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
  }

  private func stagedFile(_ bytes: Data) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mountmate-test-\(UUID().uuidString)")
    try? bytes.write(to: url, options: .atomic)
    return url
  }

  func testSha256HexMatchesKnownVector() {
    XCTAssertEqual(
      PersistenceManager.sha256Hex(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  // MARK: - Privileged fstab command

  private func temporaryPath(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("mountmate-test-\(label)-\(UUID().uuidString)")
  }

  /// Contents the field validation already rejects, but the command builder
  /// must still carry byte for byte: quotes, `$`, backticks, backslashes,
  /// several trailing newlines and no shell-level meaning anywhere.
  private let hostileContents = Data(
    ("# MountMate block: it's $HOME `id` $(id) \\ \"x\" ; rm -rf /\n\n"
      + "UUID=A none apfs rw\n\n\n").utf8)

  func testStagedContentsLoadCommandAcceptsUntouchedFile() {
    let bytes = Data("# MountMate block: DISK1-VOL1\n".utf8)
    let url = stagedFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }

    let result = runShell(
      PersistenceManager.stagedContentsLoadCommand(path: url.path, bytes: bytes))
    XCTAssertEqual(result.exitCode, 0)
  }

  func testStagedContentsLoadCommandAbortsAfterSwap() {
    let bytes = Data("# MountMate block: DISK1-VOL1\n".utf8)
    let url = stagedFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    try? Data("rm -rf /".utf8).write(to: url, options: .atomic)

    let result = runShell(
      PersistenceManager.stagedContentsLoadCommand(path: url.path, bytes: bytes))
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains(PersistenceManager.stagedFstabChangedMarker))
  }

  func testStagedContentsLoadCommandAbortsForMissingFile() {
    let url = temporaryPath("missing")

    let result = runShell(
      PersistenceManager.stagedContentsLoadCommand(path: url.path, bytes: Data("x".utf8)))
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains(PersistenceManager.stagedFstabChangedMarker))
  }

  func testStagedContentsLoadCommandRejectsDroppedTrailingNewline() {
    // Command substitution strips trailing newlines; the sentinel keeps
    // them, so a file that only differs there is still a mismatch.
    let url = stagedFile(Data("UUID=A none apfs rw".utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let result = runShell(
      PersistenceManager.stagedContentsLoadCommand(
        path: url.path, bytes: Data("UUID=A none apfs rw\n".utf8)))
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains(PersistenceManager.stagedFstabChangedMarker))
  }

  func testSystemFstabWriteCommandReadsStagedFileOnce() {
    let stagedPath = "/tmp/mountmate-fstab-it's $x"
    let command = PersistenceManager.systemFstabWriteCommand(
      stagedPath: stagedPath, stagedData: hostileContents, expectedCurrent: Data())

    let quotedPath = stagedPath.shellQuoted
    XCTAssertEqual(command.components(separatedBy: quotedPath).count - 1, 1)
    XCTAssertEqual(command.components(separatedBy: "/bin/cat").count - 1, 1)
    XCTAssertFalse(command.contains("cmp"))
    // The contents themselves never appear in the command, only their digest.
    XCTAssertFalse(command.contains("rm -rf"))
    XCTAssertTrue(command.contains(PersistenceManager.sha256Hex(hostileContents)))

    // Load, then the /etc/fstab guard, then the write from the variable.
    let load = command.range(of: "/bin/cat")!.lowerBound
    let guardCheck = command.range(of: PersistenceManager.sha256Hex(Data()))!.lowerBound
    let write = command.range(of: "> '/etc/fstab'")!.lowerBound
    XCTAssertLessThan(load, guardCheck)
    XCTAssertLessThan(guardCheck, write)
    XCTAssertTrue(
      command.contains(
        "printf '%s' \"$\(PersistenceManager.stagedContentsVariable)\" > '/etc/fstab'"))
  }

  func testSystemFstabWriteCommandWritesStagedBytesExactly() throws {
    let staged = stagedFile(hostileContents)
    let target = temporaryPath("target")
    let current = Data("# old\n".utf8)
    try current.write(to: target)
    defer {
      try? FileManager.default.removeItem(at: staged)
      try? FileManager.default.removeItem(at: target)
    }

    // chown root:wheel fails without root; everything before it must work.
    let result = runShell(
      PersistenceManager.systemFstabWriteCommand(
        stagedPath: staged.path, stagedData: hostileContents, expectedCurrent: current,
        fstabPath: target.path))
    XCTAssertFalse(result.stderr.contains("MOUNTMATE_"), result.stderr)
    XCTAssertEqual(try Data(contentsOf: target), hostileContents)
  }

  func testSystemFstabWriteCommandAbortsWhenStagedFileWasSwapped() throws {
    let staged = stagedFile(Data("swapped\n".utf8))
    let target = temporaryPath("target")
    let current = Data("# old\n".utf8)
    try current.write(to: target)
    defer {
      try? FileManager.default.removeItem(at: staged)
      try? FileManager.default.removeItem(at: target)
    }

    let result = runShell(
      PersistenceManager.systemFstabWriteCommand(
        stagedPath: staged.path, stagedData: hostileContents, expectedCurrent: current,
        fstabPath: target.path))
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains(PersistenceManager.stagedFstabChangedMarker))
    XCTAssertEqual(try Data(contentsOf: target), current)
  }

  func testSystemFstabWriteCommandAbortsWhenFstabChanged() throws {
    let staged = stagedFile(hostileContents)
    let target = temporaryPath("target")
    try Data("# edited meanwhile\n".utf8).write(to: target)
    defer {
      try? FileManager.default.removeItem(at: staged)
      try? FileManager.default.removeItem(at: target)
    }

    let result = runShell(
      PersistenceManager.systemFstabWriteCommand(
        stagedPath: staged.path, stagedData: hostileContents,
        expectedCurrent: Data("# old\n".utf8), fstabPath: target.path))
    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("MOUNTMATE_FSTAB_CHANGED"))
    XCTAssertEqual(try Data(contentsOf: target), Data("# edited meanwhile\n".utf8))
  }

  func testSystemFstabWriteCommandMissingFstabMatchesOnlyEmptyExpectation() {
    let staged = stagedFile(hostileContents)
    let target = temporaryPath("absent")
    defer {
      try? FileManager.default.removeItem(at: staged)
      try? FileManager.default.removeItem(at: target)
    }

    let refused = runShell(
      PersistenceManager.systemFstabWriteCommand(
        stagedPath: staged.path, stagedData: hostileContents,
        expectedCurrent: Data("# old\n".utf8), fstabPath: target.path))
    XCTAssertTrue(refused.stderr.contains("MOUNTMATE_FSTAB_CHANGED"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

    _ = runShell(
      PersistenceManager.systemFstabWriteCommand(
        stagedPath: staged.path, stagedData: hostileContents, expectedCurrent: Data(),
        fstabPath: target.path))
    XCTAssertEqual(try? Data(contentsOf: target), hostileContents)
  }

  func testSystemFstabWriteCommandRemovesFileWithoutStagedCopy() throws {
    let target = temporaryPath("target")
    let current = Data("# old\n".utf8)
    try current.write(to: target)
    defer { try? FileManager.default.removeItem(at: target) }

    let command = PersistenceManager.systemFstabWriteCommand(
      stagedPath: nil, stagedData: Data(), expectedCurrent: current, fstabPath: target.path)
    XCTAssertFalse(command.contains("/bin/cat"))
    let result = runShell(command)
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
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

  // MARK: - feedbackMessage

  private typealias Change = PersistenceManager.StartupRuleChange

  func testFeedbackNamesTheSingleDiskThatWasBlocked() {
    let message = PersistenceManager.feedbackMessage(
      for: Change(addedNames: ["Backup"], removedCount: 0, ruleCount: 1),
      enabled: true, fromToggle: false)
    XCTAssertNotNil(message)
    XCTAssertTrue(message!.contains("Backup"))
  }

  func testFeedbackForTurningOffMentionsRemoval() {
    XCTAssertNotNil(
      PersistenceManager.feedbackMessage(
        for: Change(addedNames: [], removedCount: 2, ruleCount: 0),
        enabled: false, fromToggle: true))
  }

  func testToggleOnWithNothingToWriteStillConfirms() {
    XCTAssertNotNil(
      PersistenceManager.feedbackMessage(
        for: Change(ruleCount: 0), enabled: true, fromToggle: true))
  }

  func testNoFeedbackWhenNothingChangedOutsideTheToggle() {
    XCTAssertNil(
      PersistenceManager.feedbackMessage(
        for: Change(ruleCount: 1), enabled: true, fromToggle: false))
  }
}
