//  Created by homielab.com

import AppKit

/// Runs a shell command as root after asking for the administrator password.
///
/// macOS 26 and earlier use `osascript … with administrator privileges`,
/// which shows the system's own password prompt. Since macOS 27, a command
/// run that way can no longer create or write /etc/fstab ("Operation not
/// permitted", issue #73), while the same command run through `sudo` still
/// can. On those versions MountMate asks for the password itself and passes
/// it to `sudo` on standard input; it is never stored or logged.
enum PrivilegedShell {
  static var usesSudo: Bool {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
  }

  /// Output that callers recognize as "the user cancelled the prompt",
  /// matching what osascript prints for a dismissed password dialog.
  static let cancelledMarker = "User canceled. (-128)"

  /// Runs `command` with `/bin/sh -c` as root. Blocking; call it off the main
  /// thread (the password prompt itself is shown on the main thread).
  static func run(_ command: String, prompt: String) -> ProcessResult {
    guard usesSudo else {
      let script =
        "do shell script \(command.appleScriptStringLiteral) with prompt \(prompt.appleScriptStringLiteral) with administrator privileges"
      return runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 300)
    }

    for attempt in 1...3 {
      guard let password = askPassword(prompt: prompt, retry: attempt > 1) else {
        return ProcessResult(stdout: "", stderr: cancelledMarker, exitCode: 1, timedOut: false)
      }
      // -S: read the password from stdin. -k: ignore any cached credentials,
      // so the password typed here is always the one checked. -p "": no
      // prompt text on stderr.
      let result = runProcess(
        executable: "/usr/bin/sudo",
        arguments: ["-S", "-k", "-p", "", "/bin/sh", "-c", command],
        input: Data((password + "\n").utf8),
        timeout: 60)
      if result.succeeded || !isWrongPassword(result) { return result }
    }
    return ProcessResult(
      stdout: "",
      stderr: NSLocalizedString(
        "Incorrect administrator password.", comment: "sudo failed three times"),
      exitCode: 1, timedOut: false)
  }

  static func isWrongPassword(_ result: ProcessResult) -> Bool {
    let output = result.stderr.lowercased()
    return output.contains("incorrect password") || output.contains("sorry, try again")
  }

  private static func askPassword(prompt: String, retry: Bool) -> String? {
    if Thread.isMainThread { return showPasswordAlert(prompt: prompt, retry: retry) }
    // Safe: the main thread never waits on the queues that call this.
    return DispatchQueue.main.sync { showPasswordAlert(prompt: prompt, retry: retry) }
  }

  private static func showPasswordAlert(prompt: String, retry: Bool) -> String? {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString(
      "Administrator Password Needed", comment: "Title of MountMate's own admin password prompt")
    alert.informativeText =
      retry
      ? prompt + "\n\n"
        + NSLocalizedString(
          "The password was incorrect. Try again.", comment: "Admin password prompt retry")
      : prompt
    alert.alertStyle = .informational

    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.placeholderString = NSLocalizedString("Password", comment: "Password placeholder")
    alert.accessoryView = field
    alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
    alert.window.initialFirstResponder = field

    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let password = field.stringValue
    field.stringValue = ""
    return password
  }
}
