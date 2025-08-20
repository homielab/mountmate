//  Created by homielab.com

import Foundation

// Now accepts optional input data to be passed to the command
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
  // ----------------------------------------------------

  do {
    try task.run()
  } catch {
    return (nil, "Failed to run shell task: \(error)")
  }

  let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
  let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

  let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(
    in: .whitespacesAndNewlines)
  let error = String(data: errData, encoding: .utf8)?.trimmingCharacters(
    in: .whitespacesAndNewlines)

  return (output, error)
}
