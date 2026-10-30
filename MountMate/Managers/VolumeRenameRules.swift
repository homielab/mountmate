//  Created by homielab.com

import Foundation

/// Name checks, command arguments and failure text for "Rename Volume…".
/// Pure, so they can be tested without running diskutil.
enum VolumeRenameRules {
  /// `diskutil rename` returns quickly; anything longer means it is stuck.
  static let timeout: TimeInterval = 60

  /// Longest name most file systems accept (APFS, HFS+).
  static let defaultMaxLength = 255
  /// FAT12/16/32 volume labels hold at most 11 characters.
  static let fatMaxLength = 11
  /// exFAT volume labels hold at most 15 characters.
  static let exFATMaxLength = 15

  enum NameProblem: Equatable, Sendable {
    case empty
    case forbiddenCharacter
    case tooLong(maxLength: Int)
    /// FAT volume labels hold ASCII only.
    case nonASCII
  }

  /// The type to check names against: the kernel's type once mounted, since
  /// the partition content ("Microsoft Basic Data") can be FAT, exFAT or NTFS.
  static func effectiveFileSystemType(of volume: Volume) -> String? {
    volume.mountedFileSystemType ?? volume.fileSystemType
  }

  /// True for FAT12/16/32 ("msdos" when mounted, "MS-DOS FAT32"… otherwise).
  static func isFAT(fileSystemType: String?) -> Bool {
    let type = (fileSystemType ?? "").lowercased()
    if type.contains("exfat") { return false }
    return type.contains("fat") || type.contains("ms-dos") || type.contains("msdos")
  }

  /// The name as it will be passed to diskutil: surrounding spaces removed.
  static func normalizedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Most characters the file system of the volume allows in its name.
  /// `fileSystemType` comes from `effectiveFileSystemType(of:)`. An unmounted
  /// "Microsoft Basic Data" volume stays at 255 and diskutil decides.
  static func maxLength(fileSystemType: String?) -> Int {
    let type = (fileSystemType ?? "").lowercased()
    if type.contains("exfat") { return exFATMaxLength }
    return isFAT(fileSystemType: fileSystemType) ? fatMaxLength : defaultMaxLength
  }

  /// What is wrong with `name`, or nil when it can be used.
  static func problem(with name: String, fileSystemType: String?) -> NameProblem? {
    let name = normalizedName(name)
    if name.isEmpty { return .empty }
    if name.contains("/") || name.contains(":")
      || name.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    {
      return .forbiddenCharacter
    }
    if isFAT(fileSystemType: fileSystemType) && !name.unicodeScalars.allSatisfy(\.isASCII) {
      return .nonASCII
    }
    let limit = maxLength(fileSystemType: fileSystemType)
    if name.utf16.count > limit { return .tooLong(maxLength: limit) }
    return nil
  }

  /// Text shown under the name field for `problem`.
  static func message(for problem: NameProblem) -> String {
    switch problem {
    case .empty:
      return NSLocalizedString(
        "Enter a name.", comment: "Rename Volume: the new name is empty")
    case .forbiddenCharacter:
      return NSLocalizedString(
        "A volume name cannot contain “/” or “:”.",
        comment: "Rename Volume: the new name has a forbidden character")
    case .tooLong(let maxLength):
      return String(
        format: NSLocalizedString(
          "Use at most %d characters.",
          comment: "Rename Volume: the new name is too long; maximum number of characters"),
        maxLength)
    case .nonASCII:
      return NSLocalizedString(
        "FAT volume names can only use English letters, digits and basic symbols.",
        comment:
          "Rename Volume: the new name has accents or other non-ASCII characters on a FAT volume")
    }
  }

  /// True when `name` would actually change the volume's name.
  static func isChange(_ name: String, from currentName: String) -> Bool {
    normalizedName(name) != currentName
  }

  /// Arguments for `diskutil`. Only the volume's name changes; mount points
  /// and fstab entries are left alone.
  static func arguments(forDevice deviceIdentifier: String, newName: String) -> [String] {
    ["rename", deviceIdentifier, normalizedName(newName)]
  }

  /// Alert title and message for a failed `diskutil rename`.
  static func failure(for result: ProcessResult, volumeName: String) -> (
    title: String, message: String
  ) {
    let title = NSLocalizedString("Rename Failed", comment: "Alert title")
    let summary: String
    if !result.timedOut && DiskUtilErrorClassifier.isBusyFailure(stderr: result.stderr) {
      summary = String(
        format: NSLocalizedString(
          "Failed to rename “%@” because it is currently in use by another application.",
          comment: "Rename Volume error message"), volumeName)
    } else {
      summary = String(
        format: NSLocalizedString(
          "“%@” could not be renamed. Its file system may not support renaming from macOS (for example NTFS), or the disk may be read-only.",
          comment: "Rename Volume error message"), volumeName)
    }
    let details = DiskUtilErrorClassifier.failureMessage(for: result, timeout: timeout)
    return (
      title,
      summary + "\n\n" + NSLocalizedString("Details", comment: "Error details prefix") + ":\n"
        + details
    )
  }
}
