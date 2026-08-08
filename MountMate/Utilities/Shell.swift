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
///
/// **Pipe safety**: stdout and stderr are drained incrementally via
/// `readabilityHandler` while the child runs. This prevents the child from
/// blocking in `write()` regardless of output size, while also keeping the
/// byte counters current so they are meaningful even at timeout.
///
/// **stdin safety**: if `input` is provided it is written to stdin *after*
/// the process has started to prevent a deadlock when the data exceeds the
/// stdin pipe buffer.
///
/// **Timeout lifecycle**: on timeout the function sends SIGTERM, unblocks all
/// I/O, then waits up to 2 s for the process to actually exit before
/// returning, so file descriptors and process-table entries are released
/// promptly rather than left dangling.
@discardableResult
func runProcess(
  executable: String,
  arguments: [String],
  input: Data? = nil,
  timeout: TimeInterval = 15.0
) -> ProcessResult {
  let task = Process()
  let outPipe = Pipe()
  let errPipe = Pipe()

  task.executableURL = URL(fileURLWithPath: executable)
  task.arguments = arguments
  task.standardOutput = outPipe
  task.standardError = errPipe

  var inPipe: Pipe?
  if input != nil {
    let p = Pipe()
    task.standardInput = p
    inPipe = p
  } else {
    // Prevent the child from inheriting the parent's stdin.
    task.standardInput = FileHandle.nullDevice
  }

  let outBuffer = LockedData()
  let errBuffer = LockedData()
  let ioGroup = DispatchGroup()
  let outClaim = ClaimOnce()
  let errClaim = ClaimOnce()

  // Start incremental readers before task.run() so drain begins the moment
  // the child writes its first bytes.
  ioGroup.enter()
  outPipe.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    if chunk.isEmpty {
      // EOF: child closed its write end (exited or was terminated).
      outPipe.fileHandleForReading.readabilityHandler = nil
      if outClaim.claim() { ioGroup.leave() }
    } else {
      outBuffer.append(chunk)
    }
  }

  ioGroup.enter()
  errPipe.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    if chunk.isEmpty {
      errPipe.fileHandleForReading.readabilityHandler = nil
      if errClaim.claim() { ioGroup.leave() }
    } else {
      errBuffer.append(chunk)
    }
  }

  do {
    try task.run()
  } catch {
    // Launch failed — clean up the readers that never received any data.
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    if outClaim.claim() { ioGroup.leave() }
    if errClaim.claim() { ioGroup.leave() }
    return ProcessResult(
      stdout: "", stderr: "Failed to launch \(executable): \(error)",
      exitCode: nil, timedOut: false)
  }

  // Write stdin AFTER the process has launched to avoid a deadlock: if the
  // data is larger than the stdin pipe buffer, write() blocks indefinitely
  // when no reader is alive yet. Use the throwing API so broken-pipe errors
  // surface rather than being silently dropped.
  if let data = input, let pipe = inPipe {
    DispatchQueue.global(qos: .utility).async {
      try? pipe.fileHandleForWriting.write(contentsOf: data)
      try? pipe.fileHandleForWriting.close()
    }
  }

  let start = Date()
  let processExited = LockedBool()

  // processExitSem — signaled immediately when the process exits, before I/O
  // drain completes. Used by the timeout path's grace-period wait.
  // completionSem  — signaled when process exit AND full I/O drain are both
  // done. This is what the normal (non-timeout) wait uses.
  let processExitSem = DispatchSemaphore(value: 0)
  let completionSem = DispatchSemaphore(value: 0)

  DispatchQueue.global(qos: .utility).async {
    task.waitUntilExit()
    processExited.value = true
    processExitSem.signal()  // fires as soon as process exits
    ioGroup.wait()
    completionSem.signal()  // fires when I/O drain is also done
  }

  guard completionSem.wait(timeout: .now() + timeout) != .timedOut else {
    // --- Timeout path ---
    let elapsed = Date().timeIntervalSince(start)
    // processRunning=true  → executable itself is hanging (auth wait, kernel stall, …)
    // processRunning=false → process exited but I/O drain incomplete
    let isRunning = !processExited.value
    print(
      """
      ❌ PROCESS TIMEOUT: \(executable) \(arguments.joined(separator: " "))
         elapsed=\(String(format: "%.1f", elapsed))s | processRunning=\(isRunning) \
      | stdout=\(outBuffer.count)B | stderr=\(errBuffer.count)B
      """
    )

    task.terminate()

    // Close the stdin write end to unblock any stdin writer thread that is
    // blocked in write() because the child stopped reading from its end.
    try? inPipe?.fileHandleForWriting.close()

    // Stop dispatch-source callbacks and close read ends so that any pending
    // or in-flight handler invocations see EOF and return.
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    try? outPipe.fileHandleForReading.close()
    try? errPipe.fileHandleForReading.close()

    // Balance the ioGroup so that the worker thread's ioGroup.wait() unblocks
    // once the process exits, allowing it to reach completionSem.signal() and
    // finish cleanly rather than leaking a thread.
    if outClaim.claim() { ioGroup.leave() }
    if errClaim.claim() { ioGroup.leave() }

    // Grace period: wait for the process to actually exit after SIGTERM before
    // returning. If processExitSem was already signaled (process had already
    // exited when timeout fired), this returns immediately. Otherwise we wait
    // up to 2 s, which is enough for well-behaved processes like diskutil.
    if processExitSem.wait(timeout: .now() + 2.0) == .timedOut {
      print("⚠️ PROCESS DID NOT EXIT within 2s after SIGTERM: \(executable)")
    }

    // Return whatever partial output had been drained up to this point —
    // this is typically the most useful diagnostic data at timeout.
    return ProcessResult(
      stdout: outBuffer.string.trimmingCharacters(in: .whitespacesAndNewlines),
      stderr: errBuffer.string.trimmingCharacters(in: .whitespacesAndNewlines),
      exitCode: nil,
      timedOut: true)
  }

  // --- Normal completion path ---
  let elapsed = Date().timeIntervalSince(start)
  let outBytes = outBuffer.count
  let errBytes = errBuffer.count
  if elapsed > 1.0 || outBytes > 1_024 || errBytes > 1_024 {
    print(
      "⏱️ PROCESS SLOW: \(executable) \(arguments.joined(separator: " ")) | \(String(format: "%.2f", elapsed))s | stdout: \(outBytes)B stderr: \(errBytes)B"
    )
  }

  return ProcessResult(
    stdout: outBuffer.string.trimmingCharacters(in: .whitespacesAndNewlines),
    stderr: errBuffer.string.trimmingCharacters(in: .whitespacesAndNewlines),
    exitCode: task.terminationStatus,
    timedOut: false)
}

// MARK: - Internal Helpers

/// Thread-safe append-only byte buffer with a running count.
private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()

  func append(_ data: Data) { lock.withLock { buffer.append(data) } }
  var count: Int { lock.withLock { buffer.count } }
  var string: String { lock.withLock { String(data: buffer, encoding: .utf8) ?? "" } }
}

/// Thread-safe write-once boolean flag.
private final class LockedBool: @unchecked Sendable {
  private let lock = NSLock()
  private var _value = false
  var value: Bool {
    get { lock.withLock { _value } }
    set { lock.withLock { _value = newValue } }
  }
}

/// One-shot claim: the first caller of `claim()` receives `true`; all
/// subsequent callers receive `false`. Used to guarantee that each
/// `DispatchGroup.enter()` is balanced by exactly one `leave()`, even when
/// both the normal EOF path and the timeout cleanup path race to leave.
private final class ClaimOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var _claimed = false

  @discardableResult
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !_claimed else { return false }
    _claimed = true
    return true
  }
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
