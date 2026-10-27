//  Created by homielab.com

import CryptoKit
import Foundation

/// Reads /etc/fstab and writes it with administrator privileges. The text
/// itself comes from `FstabRules`; this type only stages it, builds the
/// privileged shell command and turns its failures into errors.
enum FstabWriter {
  /// The current file failed the `expectedCurrent` check: /etc/fstab changed
  /// between the read and the privileged write.
  static let fstabChangedErrorCode = 3
  /// The user dismissed the administrator password prompt.
  private static let adminPromptCancelledErrorCode = 4
  /// The staged copy changed on disk before the privileged shell used it.
  private static let stagedFstabChangedErrorCode = 6
  private static let fstabChangedMarker = "MOUNTMATE_FSTAB_CHANGED"
  static let stagedFstabChangedMarker = "MOUNTMATE_STAGED_FSTAB_CHANGED"

  // MARK: - Reading

  static func readSystemFstabContents() -> String {
    guard let data = FileManager.default.contents(atPath: "/etc/fstab"),
      let contents = String(data: data, encoding: .utf8)
    else { return "" }
    return contents
  }

  /// /etc/fstab as text, plus the exact bytes it was decoded from. The
  /// privileged write compares against the bytes, so a re-encoding
  /// difference (e.g. a byte-order mark) can never make it fail forever.
  struct Snapshot {
    let contents: String
    let raw: Data
  }

  static func loadSnapshot() throws -> Snapshot {
    let path = "/etc/fstab"
    guard FileManager.default.fileExists(atPath: path) else {
      return Snapshot(contents: "", raw: Data())
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let contents = String(data: raw, encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return Snapshot(contents: contents, raw: raw)
  }

  // MARK: - Writing

  /// Writes /etc/fstab with administrator privileges.
  ///
  /// `expectedCurrent` is the exact bytes the caller based `contents` on. The
  /// privileged shell checks /etc/fstab still matches it before writing, so
  /// another writer (another app, or the user editing the file) can never be
  /// silently overwritten while MountMate waits at the password prompt.
  /// MountMate's own writers run one at a time as
  /// `StartupBlockCoordinator.enqueueFstabJob` jobs.
  static func install(_ contents: String, expectedCurrent: Data) async throws {
    let normalizedContents = FstabRules.trimmedFstabContents(contents)
    // The bytes are hashed and written as one unit, so the identity the
    // privileged shell checks is exactly what was staged.
    let stagedData = normalizedContents.data(using: .utf8) ?? Data()
    let fileManager = FileManager.default
    let temporaryURL = fileManager.temporaryDirectory
      .appendingPathComponent("mountmate-fstab-\(UUID().uuidString)")

    if !stagedData.isEmpty {
      try stagedData.write(to: temporaryURL, options: .atomic)
    }
    defer { try? fileManager.removeItem(at: temporaryURL) }

    let command = systemFstabWriteCommand(
      stagedPath: stagedData.isEmpty ? nil : temporaryURL.path,
      stagedData: stagedData,
      expectedCurrent: expectedCurrent)

    let prompt = NSLocalizedString(
      "System Mount Rule Admin Prompt", comment: "Administrator password prompt for /etc/fstab")
    let result = await PrivilegedShell.run(command, prompt: prompt)
    if !result.succeeded && result.stderr.contains(fstabChangedMarker) {
      throw NSError(
        domain: "MountMate",
        code: fstabChangedErrorCode,
        userInfo: [
          NSLocalizedDescriptionKey: NSLocalizedString(
            "System Mount Rule Changed During Update",
            comment: "Error when /etc/fstab changed while MountMate was updating it")
        ])
    }
    if !result.succeeded && result.stderr.contains(stagedFstabChangedMarker) {
      throw NSError(
        domain: "MountMate",
        code: stagedFstabChangedErrorCode,
        userInfo: [
          NSLocalizedDescriptionKey: NSLocalizedString(
            "Staged Fstab File Changed",
            comment: "Error when a staged copy changed before the privileged write used it")
        ])
    }
    // osascript reports a dismissed password prompt as
    // "execution error: User canceled. (-128)". Never show that raw text.
    if !result.succeeded && result.stderr.contains("(-128)") {
      throw NSError(
        domain: "MountMate",
        code: adminPromptCancelledErrorCode,
        userInfo: [
          NSLocalizedDescriptionKey: NSLocalizedString(
            "Administrator Prompt Cancelled",
            comment: "Error when the administrator password prompt was cancelled")
        ])
    }
    // Still refused by macOS even through sudo: say so plainly and point to
    // the manual way instead of showing the raw shell error.
    if !result.succeeded && result.stderr.contains("Operation not permitted") {
      throw NSError(
        domain: "MountMate",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: NSLocalizedString(
            "System Mount Rule Blocked By macOS",
            comment: "Error when macOS refuses to let MountMate change /etc/fstab")
        ])
    }
    if !result.succeeded {
      let error =
        result.stderr.isEmpty
        ? NSLocalizedString(
          "Custom Mount Point System Error",
          comment: "Fallback custom mount point system configuration error")
        : result.stderr
      throw NSError(
        domain: "MountMate",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: error])
    }
  }

  /// True when `error` means the user dismissed the administrator prompt.
  static func isAdminPromptCancellation(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "MountMate" && nsError.code == adminPromptCancelledErrorCode
  }

  // MARK: - Privileged Command

  /// Lowercase SHA-256 hex digest of `data`: the identity a staged file must
  /// keep until the privileged shell uses it.
  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Shell variable that holds the staged contents inside the privileged
  /// shell.
  static let stagedContentsVariable = "mountmate_staged"

  /// The privileged command that replaces `fstabPath` (normally /etc/fstab)
  /// with `stagedData`, or removes it when `stagedPath` is nil.
  ///
  /// - The current file must still hash to `expectedCurrent` (a missing file
  ///   matches empty bytes), else it fails with `fstabChangedMarker`, so two
  ///   writers never silently overwrite each other's change while one waits
  ///   at the password prompt.
  /// - The staged copy lives in the user's temporary directory, where another
  ///   process could swap it. It is read exactly once into a shell variable;
  ///   the variable is hashed and the same variable is written, so nothing
  ///   reopens the file between the check and the write.
  static func systemFstabWriteCommand(
    stagedPath: String?, stagedData: Data, expectedCurrent: Data,
    fstabPath: String = "/etc/fstab"
  ) -> String {
    let target = fstabPath.shellQuoted
    let guardCommand =
      "if [ -e \(target) ]; then "
      + "[ \"$(/usr/bin/shasum -a 256 < \(target) | /usr/bin/awk '{print $1}')\" = "
      + "\"\(sha256Hex(expectedCurrent))\" ]; "
      + "else \(expectedCurrent.isEmpty ? "true" : "false"); fi "
      + "|| { echo \(fstabChangedMarker) >&2; exit 1; }"

    guard let stagedPath else {
      return "\(guardCommand); /bin/rm -f \(target)"
    }
    // Do not use `install` here. On recent macOS versions it stages the
    // destination in /etc and atomically replaces /etc/fstab with rename(2),
    // which can be rejected even after administrator authentication. Writing
    // the existing file in place avoids that protected-directory rename.
    let variable = stagedContentsVariable
    return
      "\(stagedContentsLoadCommand(path: stagedPath, bytes: stagedData)); \(guardCommand); "
      + "printf '%s' \"$\(variable)\" > \(target) && /bin/chmod 644 \(target) "
      + "&& /usr/sbin/chown root:wheel \(target)"
  }

  /// A shell snippet that reads the staged file at `path` once into
  /// `stagedContentsVariable` and fails with `stagedFstabChangedMarker`
  /// unless those bytes hash to `bytes`. A trailing sentinel keeps the
  /// final newlines command substitution would strip; a NUL byte (which the
  /// shell drops) or any swap makes the digest differ and aborts.
  static func stagedContentsLoadCommand(path: String, bytes: Data) -> String {
    let variable = stagedContentsVariable
    let fail = "{ echo \(stagedFstabChangedMarker) >&2; exit 1; }"
    return
      "\(variable)=\"$(/bin/cat \(path.shellQuoted) && printf .)\" || \(fail); "
      + "\(variable)=\"${\(variable)%.}\"; "
      + "[ \"$(printf '%s' \"$\(variable)\" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')\" = "
      + "\"\(sha256Hex(bytes))\" ] || \(fail)"
  }
}
