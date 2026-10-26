//  Created by homielab.com

import Foundation

/// Pure text rules for MountMate's /etc/fstab entries: building, finding and
/// removing the managed lines, and validating every field before it can be
/// staged for the privileged write. Nothing here reads or writes a file or
/// runs a process; `FstabWriter` does the I/O and `PersistenceManager`
/// decides what should change.
///
/// Two kinds of entries are managed, each as a comment line followed by the
/// rule it describes:
/// - custom mount points: `# MountMate custom mount: <id>` +
///   `UUID=<uuid> <escaped mount point> <fs> rw`
/// - startup blocks: `# MountMate block: <id>` + `UUID=<uuid> none <fs> rw,noauto`
enum FstabRules {
  static let mountMateFstabPrefix = "# MountMate custom mount:"
  static let mountMateBlockPrefix = "# MountMate block:"

  /// A rule field could not be written safely (control characters, malformed
  /// UUID or file-system type). Never worth a password prompt.
  static let fstabInvalidFieldErrorCode = 5

  // MARK: - Custom Mount Points

  /// `contents` with the custom mount point rule of `volumeUUID` replaced by
  /// one that mounts it at `mountPoint`.
  ///
  /// - Parameter identifier: The `VolumeCustomMountPoint.id` written in the
  ///   comment line.
  /// - Throws: An error with `fstabInvalidFieldErrorCode` when a field cannot
  ///   be written safely, or code 1 when another line already addresses the
  ///   volume.
  static func updatedFstabContents(
    from contents: String,
    volumeUUID: String,
    identifier: String,
    mountPoint: String,
    fileSystemType: String
  ) throws -> String {
    // Everything below lands in a root-written /etc/fstab line, so every field
    // is validated here — not just where the UI validates it — before any of
    // it is staged for the privileged write.
    try validateFstabField(mountPoint)
    try validateFstabField(identifier)
    guard isStrictFstabUUID(volumeUUID), isPlainFstabFileSystemType(fileSystemType)
    else {
      throw NSError(
        domain: "MountMate", code: fstabInvalidFieldErrorCode,
        userInfo: [
          NSLocalizedDescriptionKey: NSLocalizedString(
            "Custom Mount Point System Error",
            comment: "Fallback custom mount point system configuration error")
        ])
    }

    let withoutManagedEntry = removingCustomMountEntry(volumeUUID: volumeUUID, from: contents)
    let activeLines = withoutManagedEntry.components(separatedBy: .newlines)

    if activeLines.contains(where: { isConflictingFstabEntry($0, volumeUUID: volumeUUID) }) {
      throw NSError(
        domain: "MountMate",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: NSLocalizedString(
            "Custom Mount Point System Conflict",
            comment: "Custom mount point system configuration error")
        ])
    }

    var normalized = trimmedFstabContents(withoutManagedEntry)
    if !normalized.isEmpty {
      normalized += "\n"
    }

    let entryLine =
      "UUID=\(volumeUUID) \(fstabEscapedField(mountPoint)) \(fileSystemType) rw"
    normalized += "\(managedFstabComment(identifier: identifier))\n\(entryLine)\n"
    return normalized
  }

  /// `contents` without MountMate's custom mount point rule for `volumeUUID`.
  static func removingCustomMountEntry(volumeUUID: String, from contents: String) -> String {
    removingManagedFstabEntries(
      volumeUUID: volumeUUID, kinds: [mountMateFstabPrefix], from: contents)
  }

  static func managedFstabComment(identifier: String) -> String {
    "\(mountMateFstabPrefix) \(identifier)"
  }

  /// True when `line` is an active rule for exactly `volumeUUID` (not a
  /// comment, and not a longer UUID that merely starts with it).
  static func isConflictingFstabEntry(_ line: String, volumeUUID: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
    let uuidPrefix = "UUID=\(volumeUUID)"
    guard trimmed.hasPrefix(uuidPrefix), trimmed.count > uuidPrefix.count else { return false }
    let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: uuidPrefix.count)
    return trimmed[separatorIndex].isWhitespace
  }

  /// fstab(5) octal escapes for the characters that would otherwise split a
  /// field: backslash, space and tab.
  static func fstabEscapedField(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: " ", with: "\\040")
      .replacingOccurrences(of: "\t", with: "\\011")
  }

  // MARK: - Startup Blocking

  /// What one startup-rule update changed in /etc/fstab.
  struct StartupRuleChange {
    var addedNames: [String] = []
    var removedCount = 0
    /// Rules present after the update.
    var ruleCount = 0
    var wroteFile: Bool { !addedNames.isEmpty || removedCount > 0 }
  }

  /// The confirmation shown after a user-initiated update, or nil when there
  /// is nothing worth saying.
  static func feedbackMessage(
    for change: StartupRuleChange, enabled: Bool, fromToggle: Bool
  ) -> String? {
    if change.wroteFile {
      if change.removedCount == 0, change.addedNames.count == 1 {
        return String(
          format: NSLocalizedString(
            "“%@” is now blocked at startup.", comment: "Startup rule added for one disk"),
          change.addedNames[0])
      }
      if change.removedCount == 0 {
        return PluralizedString.format("startup.blocked.added", change.addedNames.count)
      }
      if change.addedNames.isEmpty {
        return enabled
          ? NSLocalizedString("Startup block removed.", comment: "Startup rule removed")
          : NSLocalizedString(
            "Block at Startup is off. All startup rules were removed.",
            comment: "Startup blocking turned off")
      }
      return NSLocalizedString("Startup blocking updated.", comment: "Startup rules changed")
    }
    // Turned on, but no blocked disk is connected to read its format from.
    if fromToggle, enabled, change.ruleCount == 0 {
      return NSLocalizedString(
        "Block at Startup is on. Blocked disks get their startup rule the next time they're connected.",
        comment: "Startup blocking on, nothing to write yet")
    }
    return nil
  }

  /// How the startup-block rules in /etc/fstab differ from the wanted state,
  /// before the connected volumes are checked.
  struct StartupBlockDiff {
    /// Volume UUIDs (uppercased) that have a MountMate startup-block rule.
    var present: Set<String>
    /// Rules to remove: present but no longer wanted.
    var stale: Set<String>
    /// Wanted rules that are missing, sorted by UUID. Each still needs a
    /// `startupBlockEligibility` check of the connected volume.
    var missing: [(uuid: String, info: ManagedVolumeInfo)]
    /// Wanted volumes that get no rule because another line already
    /// addresses them (see `hasOtherFstabEntry`).
    var alreadyHasEntry: [ManagedVolumeInfo]
  }

  /// Compares the startup-block rules in `contents` with `blockedInfos`.
  /// With `enabled` off, no rule is wanted, so every present rule is stale.
  /// Entries without a volume UUID can never have a rule and are ignored.
  static func startupBlockDiff(
    enabled: Bool, blockedInfos: [ManagedVolumeInfo], contents: String
  ) -> StartupBlockDiff {
    let present = managedFstabVolumeUUIDs(kinds: [mountMateBlockPrefix], in: contents)
    let desired: [String: ManagedVolumeInfo] =
      enabled
      ? Dictionary(
        blockedInfos.compactMap { info in
          PersistenceManager.normalizedSystemVolumeUUID(info.volumeUUID).map { ($0, info) }
        }, uniquingKeysWith: { first, _ in first })
      : [:]

    var missing: [(uuid: String, info: ManagedVolumeInfo)] = []
    var alreadyHasEntry: [ManagedVolumeInfo] = []
    for (uuid, info) in desired.sorted(by: { $0.key < $1.key }) where !present.contains(uuid) {
      if hasOtherFstabEntry(volumeUUID: uuid, in: contents) {
        alreadyHasEntry.append(info)
      } else {
        missing.append((uuid, info))
      }
    }

    return StartupBlockDiff(
      present: present, stale: present.subtracting(desired.keys), missing: missing,
      alreadyHasEntry: alreadyHasEntry)
  }

  /// A startup-block rule to add for a connected, eligible volume.
  struct StartupBlockAddition {
    let uuid: String
    let fileSystemType: String
    let info: ManagedVolumeInfo
  }

  /// `contents` with the `stale` startup-block rules removed and rules for
  /// `additions` appended (sorted by UUID). Additions whose fields could not
  /// be written safely are left out and returned in `skipped`.
  static func applyingStartupBlockChanges(
    to contents: String, removing stale: Set<String>, adding additions: [StartupBlockAddition]
  ) -> (contents: String, skipped: [StartupBlockAddition]) {
    var updated = contents
    for uuid in stale {
      updated = removingManagedFstabEntries(
        volumeUUID: uuid, kinds: [mountMateBlockPrefix], from: updated)
    }
    updated = trimmedFstabContents(updated)
    var skipped: [StartupBlockAddition] = []
    for addition in additions.sorted(by: { $0.uuid < $1.uuid }) {
      guard
        let entry = blockedFstabEntry(
          volumeUUID: addition.uuid, fileSystemType: addition.fileSystemType,
          identifier: addition.info.id)
      else {
        skipped.append(addition)
        continue
      }
      updated += entry
    }
    return (updated, skipped)
  }

  enum StartupBlockEligibility: Equatable {
    case eligible(fileSystemType: String)
    case notConnected
    case ineligible(String)
  }

  /// Filesystem types that may get a `rw,noauto` rule: built-in macOS drivers
  /// that mount read-write anyway. Not NTFS: `rw` in /etc/fstab turns on
  /// Apple's experimental NTFS write support, which can corrupt the disk when
  /// it is later mounted by hand. Not third-party drivers (Paragon, Tuxera,
  /// macFUSE…), so a rule can never change which driver mounts a disk. Those
  /// disks keep the runtime block only.
  static let startupBlockFileSystemTypes: Set<String> = ["apfs", "hfs", "exfat", "msdos"]

  /// APFS roles that may get a startup rule. Any other role (System, Data,
  /// Preboot, Recovery, VM, Update, xART, Hardware…) is part of macOS, and a
  /// `noauto` rule for it could stop the Mac from starting up.
  static let startupBlockAllowedAPFSRoles: Set<String> = ["Backup"]

  /// Decides whether a connected volume may get a startup rule, from its
  /// `diskutil info -plist` output. Errs on the side of no rule: a skipped
  /// volume is still blocked at runtime, while a wrong rule affects boot.
  static func startupBlockEligibility(
    plist: [String: Any], bootAPFSContainer: String?, apfsRoles: [String]?
  ) -> StartupBlockEligibility {
    let mountPoint = (plist["MountPoint"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if mountPoint == "/" || mountPoint.hasPrefix("/System/Volumes/") {
      return .ineligible("it is a macOS system volume")
    }

    let container = plist["APFSContainerReference"] as? String
    if let container {
      // Fail closed: without knowing the startup disk's container, no APFS
      // volume can be shown to be outside it.
      guard let bootAPFSContainer else {
        return .ineligible("the startup disk's APFS container could not be determined")
      }
      if container == bootAPFSContainer {
        return .ineligible("it is in the startup disk's APFS container")
      }
    }

    guard let rawType = (plist["FilesystemType"] as? String)?.lowercased(),
      startupBlockFileSystemTypes.contains(rawType)
    else {
      return .ineligible("its file system is not handled by a built-in macOS driver")
    }

    if rawType == "apfs" || container != nil {
      // Unknown roles are treated as system roles.
      guard let apfsRoles, Set(apfsRoles).isSubset(of: startupBlockAllowedAPFSRoles) else {
        return .ineligible("it has a macOS system role")
      }
    }

    return .eligible(fileSystemType: rawType)
  }

  /// The /etc/fstab comment+rule pair for a blocked volume. `none` as the
  /// mount point plus `noauto` makes macOS skip the automatic mount while
  /// leaving manual mounts possible. Returns nil when a field could not be
  /// written safely (see `validateFstabField`); callers skip the volume.
  static func blockedFstabEntry(
    volumeUUID: String, fileSystemType: String, identifier: String
  ) -> String? {
    guard isStrictFstabUUID(volumeUUID), isPlainFstabFileSystemType(fileSystemType),
      !containsUnsafeFstabCharacter(identifier)
    else { return nil }
    return
      "\(mountMateBlockPrefix) \(identifier)\nUUID=\(volumeUUID) none \(fileSystemType) rw,noauto\n"
  }

  // MARK: - File System Types

  /// Maps a diskutil plist (plus a fallback raw value) to the filesystem type
  /// string used in /etc/fstab entries.
  static func fstabFileSystemType(plist: [String: Any]?, fallback: String?) -> String? {
    let candidates = [
      plist?["FilesystemType"] as? String,
      plist?["FilesystemName"] as? String,
      plist?["Content"] as? String,
      fallback,
    ].compactMap { $0 }

    for candidate in candidates {
      if let mapped = mapFstabFileSystemType(candidate) {
        return mapped
      }
    }

    return nil
  }

  static func mapFstabFileSystemType(_ rawValue: String) -> String? {
    let value = rawValue.lowercased()
    if value.contains("apfs") { return "apfs" }
    if value.contains("hfs") { return "hfs" }
    if value.contains("exfat") { return "exfat" }
    if value.contains("msdos") || value.contains("dos_fat") || value.contains("fat32")
      || value.contains("fat")
    {
      return "msdos"
    }
    if value.contains("ntfs") { return "ntfs" }

    let normalized = value.filter { $0.isLetter || $0.isNumber }
    return normalized.isEmpty ? nil : normalized
  }

  // MARK: - Managed Entries

  /// Removes MountMate-managed comment+entry pairs of the given `kinds`
  /// (comment prefixes) that address `volumeUUID`. Matching by UUID keeps
  /// removal working even when the volume's last-known identifiers have
  /// changed.
  static func removingManagedFstabEntries(
    volumeUUID: String, kinds: Set<String>, from contents: String
  ) -> String {
    let lines = contents.components(separatedBy: .newlines)
    var filtered: [String] = []
    var index = 0

    while index < lines.count {
      if let kind = managedPairKind(at: index, in: lines), kinds.contains(kind),
        entryAddressesUUID(lines[index + 1], volumeUUID)
      {
        index += 2
        continue
      }
      filtered.append(lines[index])
      index += 1
    }

    return trimmedFstabContents(filtered.joined(separator: "\n"))
  }

  private static func managedFstabKind(of line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix(mountMateFstabPrefix) { return mountMateFstabPrefix }
    if trimmed.hasPrefix(mountMateBlockPrefix) { return mountMateBlockPrefix }
    return nil
  }

  /// The managed kind of the comment+entry pair starting at `index`, or nil.
  /// A startup-block comment only counts when the next line really is a
  /// MountMate block rule, so a comment left behind by a hand edit can never
  /// make the user's own following line look like MountMate's.
  private static func managedPairKind(at index: Int, in lines: [String]) -> String? {
    guard let kind = managedFstabKind(of: lines[index]), index + 1 < lines.count else {
      return nil
    }
    if kind == mountMateBlockPrefix && !isBlockRuleLine(lines[index + 1]) { return nil }
    return kind
  }

  /// `UUID=<uuid> none <fs> <options containing noauto>`
  static func isBlockRuleLine(_ line: String) -> Bool {
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard fields.count >= 4, fields[0].hasPrefix("UUID="), fields[0].count > 5,
      fields[1] == "none"
    else { return false }
    return fields[3].split(separator: ",").contains("noauto")
  }

  /// Volume UUIDs (uppercased) addressed by the managed entries of `kinds`.
  static func managedFstabVolumeUUIDs(kinds: Set<String>, in contents: String) -> Set<String> {
    let lines = contents.components(separatedBy: .newlines)
    var uuids: Set<String> = []
    var index = 0

    while index < lines.count {
      if let kind = managedPairKind(at: index, in: lines), kinds.contains(kind) {
        let entry = lines[index + 1].trimmingCharacters(in: .whitespaces)
        if entry.hasPrefix("UUID=") {
          let uuid = entry.dropFirst("UUID=".count).prefix { !$0.isWhitespace }
          if !uuid.isEmpty {
            uuids.insert(String(uuid).uppercased())
          }
        }
        index += 2
        continue
      }
      index += 1
    }

    return uuids
  }

  /// True when an fstab line other than a MountMate startup-block rule
  /// addresses `volumeUUID` (a custom mount point, or a rule the user wrote
  /// by hand). A second line for the same volume would conflict, so no
  /// startup-block rule is added in that case.
  static func hasOtherFstabEntry(volumeUUID: String, in contents: String) -> Bool {
    let lines = contents.components(separatedBy: .newlines)
    var index = 0

    while index < lines.count {
      if managedPairKind(at: index, in: lines) == mountMateBlockPrefix {
        index += 2
        continue
      }
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      if !trimmed.hasPrefix("#"), entryAddressesUUID(trimmed, volumeUUID) {
        return true
      }
      index += 1
    }
    return false
  }

  private static func entryAddressesUUID(_ line: String, _ volumeUUID: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("UUID=") else { return false }
    let uuid = trimmed.dropFirst("UUID=".count).prefix { !$0.isWhitespace }
    return uuid.lowercased() == volumeUUID.lowercased()
  }

  static func trimmedFstabContents(_ contents: String) -> String {
    let lines = contents.components(separatedBy: .newlines)
    var end = lines.count
    while end > 0 && lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
      end -= 1
    }

    guard end > 0 else { return "" }
    return lines[..<end].joined(separator: "\n") + "\n"
  }

  // MARK: - Field Validation

  /// True when `value` has a character that must never be written into an
  /// /etc/fstab rule: control characters and line or paragraph separators. A
  /// newline would end the field and start a line of the attacker's choosing,
  /// and `fstabEscapedField` only encodes spaces, tabs and backslashes.
  /// Spaces and tabs themselves stay allowed (they are escaped), as does any
  /// printable Unicode character.
  static func containsUnsafeFstabCharacter(_ value: String) -> Bool {
    value.contains { character in
      guard character != "\t" else { return false }
      return character.isNewline
        || character.unicodeScalars.contains {
          CharacterSet.controlCharacters.contains($0)
            || CharacterSet.illegalCharacters.contains($0)
        }
    }
  }

  /// Strict UUID shape (8-4-4-4-12 hexadecimal) for values interpolated into
  /// /etc/fstab rules. `UUID(uuidString:)` also accepts brace and urn forms,
  /// which this rejects.
  static func isStrictFstabUUID(_ value: String) -> Bool {
    let lengths = [8, 4, 4, 4, 12]
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == lengths.count, zip(parts, lengths).allSatisfy({ $0.0.count == $0.1 })
    else { return false }
    return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
  }

  /// Only lowercase letters and digits — what `mapFstabFileSystemType`
  /// produces and what is safe as the file-system-type field of a rule.
  static func isPlainFstabFileSystemType(_ value: String) -> Bool {
    !value.isEmpty && value == value.lowercased()
      && value.allSatisfy { $0.isLetter || $0.isNumber }
  }

  /// Throws when `value` cannot be written into an /etc/fstab field. The
  /// message names the mount point, the only rule field a user can type.
  static func validateFstabField(_ value: String) throws {
    guard containsUnsafeFstabCharacter(value) else { return }
    throw NSError(
      domain: "MountMate", code: fstabInvalidFieldErrorCode,
      userInfo: [
        NSLocalizedDescriptionKey: NSLocalizedString(
          "Custom Mount Point Control Characters",
          comment: "Custom mount point validation")
      ])
  }
}
