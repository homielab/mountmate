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

  /// Turns the process result into an alert title and informative message.
  static func outcome(for result: ProcessResult, volumeName: String) -> Outcome {
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

    var message = String(
      format: NSLocalizedString(
        "Problems were found on “%@”. Use First Aid in Disk Utility to repair this volume.",
        comment: "Alert message: volume verification found errors"),
      volumeName)
    if let detail = failureDetail(result) {
      message += "\n\n" + detail
    }
    return Outcome(title: title, message: message, succeeded: false)
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
