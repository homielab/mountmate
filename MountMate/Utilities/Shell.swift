//  Created by homielab.com

import Foundation

@discardableResult
func runShell(_ command: String) -> (output: String?, error: String?) {
    let task = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()
    
    task.standardOutput = outPipe
    task.standardError = errPipe
    task.arguments = ["-c", command]
    task.launchPath = "/bin/zsh"
    task.standardInput = nil

    do {
        try task.run()
    } catch {
        return (nil, "Failed to run shell task: \(error)")
    }
    
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    
    let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let error = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    
    return (output, error)
}