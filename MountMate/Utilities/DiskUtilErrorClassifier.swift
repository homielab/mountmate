import Foundation

/// The disk action a diskutil call was part of.
enum DiskOperation: Sendable { case mount, unmount, eject }

/// What a failed diskutil call means for the user.
enum DiskUtilError: Equatable, Sendable {
  case mountEFIVolume
  /// "At least one volume could not be unmounted" while ejecting a disk.
  case unmountBusyVolume
  /// Busy or in use; carries the name of the blocking process when diskutil named one.
  case inUse(process: String?)
  case mountLockedVolume
  case other
}

/// Turns diskutil output into a classification and user-facing text.
/// Pure functions, so every message can be tested without a disk.
enum DiskUtilErrorClassifier {
  /// User-facing description of a failed diskutil run.
  static func failureMessage(for result: ProcessResult, timeout: TimeInterval) -> String {
    if result.timedOut {
      return String(
        format: NSLocalizedString(
          "The operation timed out after %d seconds.",
          comment: "Disk operation error; number of seconds"), Int32(timeout))
    }
    if result.stderr.isEmpty {
      return String(
        format: NSLocalizedString(
          "diskutil exited with code %d.", comment: "Disk operation error; process exit code"),
        result.exitCode ?? -1)
    }
    return result.stderr
  }

  /// True when `diskutil apfs unlockVolume` rejected the passphrase itself
  /// (as opposed to a timeout or any other failure).
  static func isWrongPassphrase(_ result: ProcessResult) -> Bool {
    guard !result.timedOut else { return false }
    let output = "\(result.stdout)\n\(result.stderr)".lowercased()
    if output.contains("-69749") || output.contains("-69808") { return true }
    return (output.contains("passphrase") || output.contains("password"))
      && (output.contains("incorrect") || output.contains("invalid")
        || output.contains("wrong") || output.contains("not valid"))
  }

  static func classify(_ rawError: String, for name: String, operation: DiskOperation)
    -> DiskUtilError
  {
    let lowerCaseError = rawError.lowercased()

    if operation == .mount && name.uppercased() == "EFI" {
      return .mountEFIVolume
    }

    if lowerCaseError.contains("at least one volume could not be unmounted") {
      return .unmountBusyVolume
    }

    if lowerCaseError.contains("busy") || lowerCaseError.contains("in use")
      || lowerCaseError.contains("dissented by pid")
    {
      return .inUse(process: blockingProcessName(in: rawError))
    }

    if rawError.contains(
      "This is an encrypted and locked APFS Volume; use \"diskutil apfs unlockVolume\"")
    {
      return .mountLockedVolume
    }

    return .other
  }

  /// Last path component of the executable diskutil names as the blocker,
  /// e.g. `(/usr/bin/foo)` or `dissented by PID 12 (/usr/bin/foo)`.
  static func blockingProcessName(in rawError: String) -> String? {
    guard
      let range = rawError.range(
        of: "(dissented by PID \\d+ )?\\((/[^)]+)\\)",
        options: [.regularExpression, .caseInsensitive])
    else { return nil }
    let match = String(rawError[range])
    guard let start = match.firstIndex(of: "("), let end = match.firstIndex(of: ")") else {
      return nil
    }
    let path = String(match[match.index(after: start)..<end])
    return URL(fileURLWithPath: path).lastPathComponent
  }

  /// Alert title and message for a failure that is shown as a plain alert
  /// (every case except a locked volume, which asks for the password).
  static func presentation(
    for error: DiskUtilError, name: String, operation: DiskOperation, details: String
  ) -> (title: String, message: String)? {
    let detailsBlock =
      "\n\n" + NSLocalizedString("Details", comment: "Error details prefix") + ":\n" + details

    switch error {
    case .mountLockedVolume:
      return nil
    case .mountEFIVolume:
      return (
        NSLocalizedString("Mount Failed", comment: "Alert title"),
        NSLocalizedString(
          "The “EFI” partition cannot be mounted directly. This is a special system partition and this behavior is normal.",
          comment: "Error message")
      )
    case .unmountBusyVolume:
      return (
        NSLocalizedString("Eject Failed", comment: "Alert title"),
        String(
          format: NSLocalizedString(
            "Failed to eject “%@” because one of its volumes is busy or in use.",
            comment: "Error message"), name) + detailsBlock
      )
    case .inUse(let process):
      let summary: String
      switch (operation, process) {
      case (.mount, let proc?):
        summary = String(
          format: NSLocalizedString(
            "Failed to mount “%@” because it is currently in use by “%@”.",
            comment: "Error message"), name, proc)
      case (.mount, nil):
        summary = String(
          format: NSLocalizedString(
            "Failed to mount “%@” because it is currently in use by another application.",
            comment: "Error message"), name)
      case (.unmount, let proc?):
        summary = String(
          format: NSLocalizedString(
            "Failed to unmount “%@” because it is currently in use by “%@”.",
            comment: "Error message"), name, proc)
      case (.unmount, nil):
        summary = String(
          format: NSLocalizedString(
            "Failed to unmount “%@” because it is currently in use by another application.",
            comment: "Error message"), name)
      case (.eject, let proc?):
        summary = String(
          format: NSLocalizedString(
            "Failed to eject “%@” because it is currently in use by “%@”.",
            comment: "Error message"), name, proc)
      case (.eject, nil):
        summary = String(
          format: NSLocalizedString(
            "Failed to eject “%@” because it is currently in use by another application.",
            comment: "Error message"), name)
      }
      return (failureTitle(for: operation), summary + detailsBlock)
    case .other:
      let unknown: String
      switch operation {
      case .mount:
        unknown = String(
          format: NSLocalizedString(
            "An unknown error occurred while trying to mount “%@”.", comment: "Error message"),
          name)
      case .unmount:
        unknown = String(
          format: NSLocalizedString(
            "An unknown error occurred while trying to unmount “%@”.", comment: "Error message"),
          name)
      case .eject:
        unknown = String(
          format: NSLocalizedString(
            "An unknown error occurred while trying to eject “%@”.", comment: "Error message"),
          name)
      }
      return (failureTitle(for: operation), unknown + detailsBlock)
    }
  }

  private static func failureTitle(for operation: DiskOperation) -> String {
    switch operation {
    case .mount: return NSLocalizedString("Mount Failed", comment: "Alert title")
    case .unmount: return NSLocalizedString("Unmount Failed", comment: "Alert title")
    case .eject: return NSLocalizedString("Eject Failed", comment: "Alert title")
    }
  }
}
