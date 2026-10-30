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

  /// The volume's file system may not get a custom mount point rule (see
  /// `customMountPointFileSystemTypes`). Never worth a password prompt.
  static let fstabUnsupportedFileSystemErrorCode = 7

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
    // `rw` for any other type would change how macOS mounts the disk (see
    // `customMountPointFileSystemTypes`), so such a rule is never built.
    guard customMountPointFileSystemTypes.contains(fileSystemType) else {
      throw NSError(
        domain: "MountMate", code: fstabUnsupportedFileSystemErrorCode,
        userInfo: [
          NSLocalizedDescriptionKey: unsupportedFileSystemMessage(
            name: unsupportedFileSystemName(rawType: fileSystemType, displayName: nil))
        ])
    }

    let withoutManagedEntry = removingCustomMountEntry(volumeUUID: volumeUUID, from: contents)
    let activeLines = fstabLines(withoutManagedEntry)

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

    let eol = lineEnding(of: contents)
    var normalized = trimmedFstabContents(withoutManagedEntry)
    if !normalized.isEmpty {
      normalized += eol
    }

    let entryLine =
      "UUID=\(volumeUUID) \(fstabEscapedField(mountPoint)) \(fileSystemType) rw"
    normalized += "\(managedFstabComment(identifier: identifier))\(eol)\(entryLine)\(eol)"
    return normalized
  }

  /// File systems that may get a custom mount point rule: the built-in
  /// macOS drivers of `startupBlockFileSystemTypes`, for the same reasons.
  /// `rw` for NTFS turns on Apple's experimental NTFS write support, which
  /// can corrupt the disk, and a rule for a disk of a third-party driver
  /// (Paragon `ufsd_NTFS`, Tuxera `tuxera_ntfs`, macFUSE…) would hand it to
  /// the built-in driver instead.
  static var customMountPointFileSystemTypes: Set<String> { startupBlockFileSystemTypes }

  enum CustomMountPointFileSystem: Equatable {
    /// The type to write in the rule.
    case supported(String)
    /// Refused; the name to show the user ("NTFS", "ext4"…).
    case unsupported(name: String)
    /// No file system type could be read.
    case unknown
  }

  /// Whether a volume may get a custom mount point, from its `diskutil info
  /// -plist` output (nil when that failed) and, as a fallback, the
  /// partition content or file system name of the disk list. The raw
  /// `FilesystemType` decides when present, so a third-party driver's type
  /// such as `ufsd_NTFS` is refused even though it maps to "ntfs".
  static func customMountPointFileSystem(plist: [String: Any]?, fallback: String?)
    -> CustomMountPointFileSystem
  {
    let displayName = (plist?["FilesystemName"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let rawType = (plist?["FilesystemType"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !rawType.isEmpty
    {
      let type = rawType.lowercased()
      return customMountPointFileSystemTypes.contains(type)
        ? .supported(type)
        : .unsupported(name: unsupportedFileSystemName(rawType: rawType, displayName: displayName))
    }
    guard let mapped = fstabFileSystemType(plist: plist, fallback: fallback) else {
      return .unknown
    }
    if customMountPointFileSystemTypes.contains(mapped) { return .supported(mapped) }
    return .unsupported(
      name: unsupportedFileSystemName(rawType: fallback ?? mapped, displayName: displayName))
  }

  /// For the menu, before any `diskutil` call: the name of the volume's file
  /// system when it is known to be refused, else nil. `mountedType` is the
  /// mount table's type of a mounted volume (exact: "ufsd_NTFS", "apfs");
  /// `contentType` the partition content of the disk list, which only
  /// tells NTFS apart when it says so ("Windows_NTFS"; "Microsoft Basic
  /// Data" can be NTFS, exFAT or FAT, so `applyCustomMountPoint` decides).
  static func knownUnsupportedCustomMountPointFileSystem(
    contentType: String?, mountedType: String?
  ) -> String? {
    if let mountedType, !mountedType.isEmpty {
      return customMountPointFileSystemTypes.contains(mountedType.lowercased())
        ? nil : unsupportedFileSystemName(rawType: mountedType, displayName: nil)
    }
    if let contentType, contentType.lowercased().contains("ntfs") { return "NTFS" }
    return nil
  }

  /// "NTFS" for every NTFS driver's type, else the file system's own name.
  static func unsupportedFileSystemName(rawType: String, displayName: String?) -> String {
    if rawType.lowercased().contains("ntfs") { return "NTFS" }
    if let displayName, !displayName.isEmpty { return displayName }
    return rawType
  }

  /// Why a volume of file system `name` gets no custom mount point.
  static func unsupportedFileSystemMessage(name: String) -> String {
    String(
      format: NSLocalizedString(
        "Custom Mount Point File System Not Allowed",
        comment: "Custom mount point refused for a file system such as NTFS; %@ = its name"),
      name)
  }

  /// A MountMate custom mount point rule found in /etc/fstab.
  struct CustomMountRule: Equatable, Identifiable {
    /// The `VolumeCustomMountPoint.id` written in the comment line.
    let identifier: String
    let volumeUUID: String
    /// As written in the rule (fstab escapes decoded).
    let mountPoint: String
    let fileSystemType: String
    var id: String { identifier }
  }

  /// Every MountMate custom mount point rule in `contents`, in file order.
  /// A comment whose next line is not a `UUID=` rule is skipped.
  static func customMountRules(in contents: String) -> [CustomMountRule] {
    let lines = fstabLines(contents)
    var rules: [CustomMountRule] = []
    for index in lines.indices.dropLast() {
      let comment = lines[index].trimmingCharacters(in: .whitespaces)
      guard comment.hasPrefix(mountMateFstabPrefix) else { continue }
      let fields = lines[index + 1].split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard fields.count >= 3, fields[0].hasPrefix("UUID="), fields[0].count > 5 else { continue }
      rules.append(
        CustomMountRule(
          identifier: comment.dropFirst(mountMateFstabPrefix.count)
            .trimmingCharacters(in: .whitespaces),
          volumeUUID: String(fields[0].dropFirst("UUID=".count)),
          mountPoint: fstabUnescapedField(String(fields[1])),
          fileSystemType: String(fields[2])))
    }
    return rules
  }

  /// Custom mount point rules an older MountMate wrote for a file system
  /// that may no longer get one (NTFS, third-party drivers). They are never
  /// changed automatically: the user removes them from Settings.
  static func unsupportedCustomMountRules(in contents: String) -> [CustomMountRule] {
    unsupportedCustomMountRules(customMountRules(in: contents))
  }

  /// The rules of `rules` whose file system may no longer get one.
  static func unsupportedCustomMountRules(_ rules: [CustomMountRule]) -> [CustomMountRule] {
    rules.filter { !customMountPointFileSystemTypes.contains($0.fileSystemType.lowercased()) }
  }

  /// Rules of an allowed file system that no saved custom mount point
  /// describes (neither by identifier nor by volume UUID), e.g. after the
  /// app's settings were reset or moved to another Mac. macOS still applies
  /// them, so Settings lists them with a Remove button. They are never
  /// changed automatically. Unsupported rules are left to
  /// `unsupportedCustomMountRules`, so no rule is listed twice.
  static func untrackedCustomMountRules(
    _ rules: [CustomMountRule], savedEntries: [VolumeCustomMountPoint]
  ) -> [CustomMountRule] {
    let savedIDs = Set(savedEntries.map(\.id))
    let savedUUIDs = Set(savedEntries.map { $0.volumeUUID.uppercased() })
    return rules.filter {
      customMountPointFileSystemTypes.contains($0.fileSystemType.lowercased())
        && !savedIDs.contains($0.identifier)
        && !savedUUIDs.contains($0.volumeUUID.uppercased())
    }
  }

  /// Reverses `fstabEscapedField` in one pass, so an escaped backslash
  /// followed by "040" stays a backslash and "040".
  static func fstabUnescapedField(_ value: String) -> String {
    var result = ""
    var rest = Substring(value)
    while let first = rest.first {
      if first == "\\" {
        if rest.hasPrefix("\\\\") {
          result.append("\\")
          rest = rest.dropFirst(2)
          continue
        }
        if rest.hasPrefix("\\040") {
          result.append(" ")
          rest = rest.dropFirst(4)
          continue
        }
        if rest.hasPrefix("\\011") {
          result.append("\t")
          rest = rest.dropFirst(4)
          continue
        }
      }
      result.append(first)
      rest = rest.dropFirst()
    }
    return result
  }

  /// `contents` without MountMate's custom mount point rule for `volumeUUID`.
  static func removingCustomMountEntry(volumeUUID: String, from contents: String) -> String {
    removingManagedFstabEntries(
      volumeUUID: volumeUUID, kinds: [mountMateFstabPrefix], from: contents)
  }

  static func managedFstabComment(identifier: String) -> String {
    "\(mountMateFstabPrefix) \(identifier)"
  }

  /// True when `line` is an active rule for exactly `volumeUUID`: not a
  /// comment, not a longer UUID that merely starts with it, and with a field
  /// after the UUID. UUIDs compare case-insensitively, like everywhere else
  /// in this file, so a hand-written lowercase rule counts too.
  static func isConflictingFstabEntry(_ line: String, volumeUUID: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.hasPrefix("#"), entryAddressesUUID(trimmed, volumeUUID) else { return false }
    return trimmed.split(whereSeparator: \.isWhitespace).count > 1
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
      updated += entry.replacingOccurrences(of: "\n", with: lineEnding(of: contents))
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
    let lines = fstabLines(contents)
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

    return trimmedFstabContents(filtered.joined(separator: lineEnding(of: contents)))
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
    let lines = fstabLines(contents)
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
    let lines = fstabLines(contents)
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
    let lines = fstabLines(contents)
    var end = lines.count
    while end > 0 && lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
      end -= 1
    }

    guard end > 0 else { return "" }
    let eol = lineEnding(of: contents)
    return lines[..<end].joined(separator: eol) + eol
  }

  /// The lines of an fstab, split at `\n`, `\r\n` or `\r`. A CRLF pair is
  /// one line break (`.newlines` would split it in two and add blank lines).
  static func fstabLines(_ contents: String) -> [String] {
    contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
  }

  /// The line ending `contents` uses, so an edited CRLF file stays CRLF and
  /// an unchanged one compares equal (and is not rewritten).
  static func lineEnding(of contents: String) -> String {
    contents.contains("\r\n") ? "\r\n" : "\n"
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
