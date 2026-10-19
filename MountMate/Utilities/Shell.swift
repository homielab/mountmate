//  Created by homielab.com

import Foundation

// MARK: - Result Type

struct ProcessResult {
  /// Trimmed standard output.
  let stdout: String
  /// Trimmed standard error.
  let stderr: String
  /// Process exit code, or `nil` when the operation timed out before the
  /// process exited.
  let exitCode: Int32?
  /// `true` when the call was abandoned after the timeout elapsed.
  let timedOut: Bool

  /// Convenience: exited with code 0 and did not time out.
  var succeeded: Bool { !timedOut && exitCode == 0 }
}

// MARK: - Direct Process Runner

/// Launches `executable` with `arguments` directly — no shell intermediary.
/// Standard output and error are redirected to temporary files so a child
/// process cannot be delayed by pipe-draining or readability-handler races.
@discardableResult
func runProcess(
  executable: String,
  arguments: [String],
  input: Data? = nil,
  timeout: TimeInterval = 15.0
) -> ProcessResult {
  let task = Process()
  let fileManager = FileManager.default
  let temporaryDirectory = fileManager.temporaryDirectory
  let stdoutURL = temporaryDirectory.appendingPathComponent(
    "mountmate-process-stdout-\(UUID().uuidString)")
  let stderrURL = temporaryDirectory.appendingPathComponent(
    "mountmate-process-stderr-\(UUID().uuidString)")

  guard
    fileManager.createFile(atPath: stdoutURL.path, contents: nil),
    fileManager.createFile(atPath: stderrURL.path, contents: nil),
    let stdoutFile = try? FileHandle(forWritingTo: stdoutURL),
    let stderrFile = try? FileHandle(forWritingTo: stderrURL)
  else {
    try? fileManager.removeItem(at: stdoutURL)
    try? fileManager.removeItem(at: stderrURL)
    return ProcessResult(
      stdout: "", stderr: "Failed to create process output files.", exitCode: nil, timedOut: false)
  }

  defer {
    try? stdoutFile.close()
    try? stderrFile.close()
    try? fileManager.removeItem(at: stdoutURL)
    try? fileManager.removeItem(at: stderrURL)
  }

  task.executableURL = URL(fileURLWithPath: executable)
  task.arguments = arguments
  task.standardOutput = stdoutFile
  task.standardError = stderrFile

  var inputPipe: Pipe?
  if input != nil {
    let pipe = Pipe()
    task.standardInput = pipe
    inputPipe = pipe
  } else {
    // Prevent the child from inheriting the parent's stdin.
    task.standardInput = FileHandle.nullDevice
  }

  let processExitSem = DispatchSemaphore(value: 0)
  task.terminationHandler = { _ in processExitSem.signal() }

  do {
    try task.run()
  } catch {
    return ProcessResult(
      stdout: "", stderr: "Failed to launch \(executable): \(error)", exitCode: nil, timedOut: false
    )
  }

  let currentQoS = DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .userInitiated
  let qosClass: DispatchQoS.QoSClass = (currentQoS == .unspecified) ? .userInitiated : currentQoS

  // Write stdin after launch so large input cannot block before the child is
  // alive and reading. If the child exits before reading everything, the
  // write fails with EPIPE; without F_SETNOSIGPIPE it would instead raise
  // SIGPIPE, which terminates the whole app.
  if let data = input, let pipe = inputPipe {
    let writeHandle = pipe.fileHandleForWriting
    _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
    DispatchQueue.global(qos: qosClass).async {
      do {
        try writeHandle.write(contentsOf: data)
      } catch {
        // Expected when the child exits early; its exit status reports why.
        print("⚠️ Could not write stdin to \(executable): \(error.localizedDescription)")
      }
      try? writeHandle.close()
    }
  }

  let start = Date()
  let timedOut = processExitSem.wait(timeout: .now() + timeout) == .timedOut
  var forcedTermination = false
  var processWasRunning = false

  if timedOut {
    processWasRunning = task.isRunning
    if processWasRunning {
      task.terminate()
    }

    // Close stdin so a writer waiting on a blocked pipe is released.
    try? inputPipe?.fileHandleForWriting.close()

    // Give SIGTERM a short grace period, then use SIGKILL if the executable is
    // still alive. File-backed output means no reader cleanup is required.
    if processExitSem.wait(timeout: .now() + 2.0) == .timedOut,
      task.isRunning
    {
      forcedTermination = true
      kill(task.processIdentifier, SIGKILL)
    }
  }

  try? stdoutFile.close()
  try? stderrFile.close()

  let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
  let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
  let stdout =
    String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines) ?? ""
  let stderr =
    String(data: stderrData, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines) ?? ""
  let elapsed = Date().timeIntervalSince(start)

  if timedOut {
    let termination = forcedTermination ? "SIGKILL" : "SIGTERM"
    print(
      "❌ PROCESS TIMEOUT: \(executable) \(redactedArguments(arguments).joined(separator: " ")) | elapsed=\(String(format: "%.1f", elapsed))s | processRunning=\(processWasRunning) | termination=\(termination) | stdout=\(stdoutData.count)B | stderr=\(stderrData.count)B"
    )
    return ProcessResult(stdout: stdout, stderr: stderr, exitCode: nil, timedOut: true)
  }

  if elapsed > 3.0 {
    print(
      "⏱️ PROCESS SLOW: \(executable) \(redactedArguments(arguments).joined(separator: " ")) | \(String(format: "%.2f", elapsed))s | stdout: \(stdoutData.count)B stderr: \(stderrData.count)B"
    )
  }

  return ProcessResult(
    stdout: stdout,
    stderr: stderr,
    exitCode: task.terminationStatus,
    timedOut: false)
}

// MARK: - Log Redaction

/// Flags whose following argument is a secret.
private let secretArgumentFlags: Set<String> = [
  "-passphrase", "-password", "--password", "-oldpassphrase", "-newpassphrase", "-pass",
]

/// Matches the password in URL user info: `scheme://user:password@host` and
/// the scheme-less `//user:password@host` form used by mount_smbfs.
/// Group 1 keeps everything up to and including the colon.
private let urlPasswordRegex = try! NSRegularExpression(
  pattern: "((?:[A-Za-z][A-Za-z0-9+.\\-]*:)?//[^/@:\\s]*:)[^/@\\s]*@")

/// `arguments` with secrets replaced by `***`, for logging. Command lines can
/// carry network share passwords (`smb://user:pass@server/share`) or
/// passphrases given after a flag; those must never reach the console log.
func redactedArguments(_ arguments: [String]) -> [String] {
  var redacted: [String] = []
  redacted.reserveCapacity(arguments.count)
  var previousWasSecretFlag = false
  for argument in arguments {
    if previousWasSecretFlag {
      redacted.append("***")
      previousWasSecretFlag = false
      continue
    }
    previousWasSecretFlag = secretArgumentFlags.contains(argument.lowercased())
    let range = NSRange(argument.startIndex..., in: argument)
    redacted.append(
      urlPasswordRegex.stringByReplacingMatches(
        in: argument, range: range, withTemplate: "$1***@"))
  }
  return redacted
}

extension String {
  var shellQuoted: String {
    "'" + self.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  var appleScriptStringLiteral: String {
    "\""
      + self
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
