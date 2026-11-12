import Foundation

/// The disk action a diskutil call was part of.
enum DiskOperation: Sendable { case mount, unmount, eject }

/// What a failed diskutil call means for the user.
enum DiskUtilError: Equatable, Sendable {
  case mountEFIVolume
  /// "At least one volume could not be unmounted" while ejecting a disk.
  case unmountBusyVolume
  /// Busy or in use; carries the friendly name of the blocking process when
  /// diskutil named one (see `BlockingProcessNames`).
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

    if lowerCaseError.contains(unmountBusyMarker) {
      return .unmountBusyVolume
    }

    if mentionsBusy(lowerCaseError) {
      return .inUse(process: blockingProcess(in: rawError)?.displayName)
    }

    if mentionsLockedVolume(lowerCaseError) {
      return .mountLockedVolume
    }

    return .other
  }

  private static let unmountBusyMarker = "at least one volume could not be unmounted"

  private static func mentionsBusy(_ lowerCaseError: String) -> Bool {
    lowerCaseError.contains("busy") || lowerCaseError.contains("in use")
      || lowerCaseError.contains("dissented by pid")
  }

  /// Matches diskutil's "encrypted and locked ... use unlockVolume" sentence
  /// loosely, so a changed wording or quoting still counts as locked.
  private static func mentionsLockedVolume(_ lowerCaseError: String) -> Bool {
    lowerCaseError.contains("encrypted and locked") || lowerCaseError.contains("unlockvolume")
  }

  /// True when a mount failed only because the volume is encrypted and still
  /// locked (stdout and stderr both checked). Same matcher as `classify`.
  static func isLockedVolumeFailure(_ result: ProcessResult) -> Bool {
    guard !result.timedOut else { return false }
    return mentionsLockedVolume("\(result.stdout)\n\(result.stderr)".lowercased())
  }

  /// True when diskutil refused because something is using the disk (a busy
  /// volume, a blocking process, or an unmount that left a volume mounted);
  /// retrying will not help. Agrees with `classify` returning `.inUse` or
  /// `.unmountBusyVolume`.
  static func isBusyFailure(stderr: String) -> Bool {
    let lower = stderr.lowercased()
    return lower.contains(unmountBusyMarker) || mentionsBusy(lower)
  }

  /// Last path component of the executable diskutil names as the blocker,
  /// e.g. `(/usr/bin/foo)` or `dissented by PID 12 (/usr/bin/foo)`.
  static func blockingProcessName(in rawError: String) -> String? {
    blockingProcessPath(in: rawError).map { URL(fileURLWithPath: $0.path).lastPathComponent }
  }

  /// The blocker diskutil names, with its friendly name and icon kind.
  static func blockingProcess(in rawError: String) -> BlockingProcess? {
    guard let found = blockingProcessPath(in: rawError) else { return nil }
    return BlockingProcessNames.describe(path: found.path, pid: found.pid)
  }

  private static func blockingProcessPath(in rawError: String) -> (path: String, pid: Int32?)? {
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
    let pid = match.range(of: "\\d+", options: .regularExpression).flatMap {
      match.lowercased().hasPrefix("dissented") ? Int32(match[$0]) : nil
    }
    return (path, pid)
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
