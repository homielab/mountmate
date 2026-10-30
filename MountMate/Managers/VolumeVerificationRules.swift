//  Created by homielab.com

import Foundation

/// Rules and outcome formatting for volume verification.
/// Pure, so command arguments and outcome alerts can be tested without
/// executing diskutil.
enum VolumeVerificationRules {
  /// Longest time to wait for `diskutil verifyVolume` before giving up. A
  /// large HFS+ disk can take many minutes, so this is generous.
  static let defaultTimeout: TimeInterval = 30 * 60

  /// Arguments for `diskutil`. Verification only — never repairs.
  static func arguments(forDevice deviceIdentifier: String) -> [String] {
    ["verifyVolume", deviceIdentifier]
  }

  struct Outcome: Equatable, Sendable {
    let title: String
    let message: String
    let succeeded: Bool
  }

  /// Why diskutil exited non-zero.
  enum FailureKind: Equatable, Sendable {
    /// The check ran and found damage: First Aid can help.
    case problemsFound
    case busy
    case unsupported
    case notMounted
    case permission
    /// Anything else: the check did not run to the end, so nothing is known.
    case unknown
  }

  /// Sorts a failed run. Only output that says the file system is damaged
  /// counts as problems; NTFS, busy or vanished volumes were never checked.
  static func failureKind(for result: ProcessResult, fileSystemType: String? = nil)
    -> FailureKind
  {
    let text = (result.stderr + "\n" + result.stdout).lowercased()
    let type = (fileSystemType ?? "").lowercased()
    if type.contains("ntfs")
      || ["not supported", "unsupported", "does not support", "unrecognized file system"]
        .contains(where: text.contains)
    {
      return .unsupported
    }
    if DiskUtilErrorClassifier.isBusyFailure(stderr: text) { return .busy }
    if ["not mounted", "could not find disk", "unable to find disk", "no such file"]
      .contains(where: text.contains)
    {
      return .notMounted
    }
    if ["permission denied", "not permitted", "not privileged"].contains(where: text.contains) {
      return .permission
    }
    if [
      "corrupt", "needs to be repaired", "-69845", "invalid", "incorrect", "exit code is 8",
    ].contains(where: text.contains) {
      return .problemsFound
    }
    return .unknown
  }

  /// Turns the process result into an alert title and informative message.
  /// diskutil's raw output is logged for Copy Diagnostics, not shown here.
  static func outcome(
    for result: ProcessResult, volumeName: String, fileSystemType: String? = nil
  ) -> Outcome {
    if result.succeeded {
      return Outcome(
        title: NSLocalizedString(
          "Volume Verified",
          comment: "Alert title: volume verification succeeded"),
        message: String(
          format: NSLocalizedString(
            "No problems were found on “%@”.",
            comment: "Alert message: volume verification succeeded"),
          volumeName),
        succeeded: true
      )
    }

    let title = NSLocalizedString(
      "Volume Verification Failed",
      comment: "Alert title: volume verification timed out or failed")

    if result.timedOut {
      return Outcome(
        title: title,
        message: String(
          format: NSLocalizedString(
            "Verification of “%@” did not finish in time. You can check it with First Aid in Disk Utility.",
            comment: "Alert message: volume verification timed out"),
          volumeName),
        succeeded: false
      )
    }

    let kind = failureKind(for: result, fileSystemType: fileSystemType)
    if kind == .problemsFound {
      return Outcome(
        title: title,
        message: String(
          format: NSLocalizedString(
            "Problems were found on “%@”. Use First Aid in Disk Utility to repair this volume.",
            comment: "Alert message: volume verification found errors"),
          volumeName),
        succeeded: false)
    }

    let reason: String
    switch kind {
    case .busy:
      reason = NSLocalizedString(
        "The volume is in use by another app. Close it and try again.",
        comment: "Could not verify reason: volume busy")
    case .unsupported:
      reason = NSLocalizedString(
        "macOS cannot check this file system (for example NTFS).",
        comment: "Could not verify reason: file system not supported")
    case .notMounted:
      reason = NSLocalizedString(
        "The volume is no longer mounted.",
        comment: "Could not verify reason: volume unmounted or unplugged")
    case .permission:
      reason = NSLocalizedString(
        "macOS did not allow the check.",
        comment: "Could not verify reason: permission denied")
    case .problemsFound, .unknown:
      reason = NSLocalizedString(
        "diskutil stopped before the check finished. Details are in Copy Diagnostics.",
        comment: "Could not verify reason: unknown failure")
    }
    return Outcome(
      title: NSLocalizedString(
        "Could Not Verify Volume",
        comment: "Alert title: verification did not run to the end; nothing is known about damage"
      ),
      message: String(
        format: NSLocalizedString(
          "“%@” was not checked. %@",
          comment: "Alert message: volume not verified; 1 = volume name, 2 = reason"),
        volumeName, reason),
      succeeded: false)
  }

  /// diskutil's own last line about the failure (stderr first, else stdout),
  /// e.g. "Error: -69845: File system verify or repair failed".
  static func failureDetail(_ result: ProcessResult) -> String? {
    for output in [result.stderr, result.stdout] {
      let lastLine = output.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty }
      if let lastLine { return lastLine }
    }
    return nil
  }
}
