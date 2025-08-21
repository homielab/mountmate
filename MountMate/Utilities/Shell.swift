//  Created by homielab.com

import Foundation

@discardableResult
func runShell(_ command: String, input: Data? = nil) -> (output: String?, error: String?) {
  let task = Process()
  let outPipe = Pipe()
  let errPipe = Pipe()

  task.standardOutput = outPipe
  task.standardError = errPipe
  task.arguments = ["-c", command]
  task.launchPath = "/bin/zsh"

  if let input = input {
    let inPipe = Pipe()
    task.standardInput = inPipe
    inPipe.fileHandleForWriting.write(input)
    try? inPipe.fileHandleForWriting.close()
  } else {
    task.standardInput = nil
  }

  let group = DispatchGroup()
  group.enter()

  task.terminationHandler = { _ in
    group.leave()
  }

  do {
    try task.run()
  } catch {
    return (nil, "Failed to run shell task: \(error)")
  }

  let timeoutResult = group.wait(timeout: .now() + 6.0)

  if timeoutResult == .timedOut {
    print(
      "❌ SHELL TIMEOUT: The command '\(command)' did not complete within 6 seconds. Terminating.")
    task.terminate()
    let timeoutError =
      "The command timed out. This often indicates a permissions issue. Please grant MountMate Full Disk Access in System Settings."
    return (nil, timeoutError)
  }

  let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
  let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

  let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(
    in: .whitespacesAndNewlines)
  let error = String(data: errData, encoding: .utf8)?.trimmingCharacters(
    in: .whitespacesAndNewlines)

  return (output, error)
}
