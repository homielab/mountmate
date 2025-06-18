//  Created by homielab.com

import Foundation

@discardableResult
func runShell(_ command: String) -> String? {
    let task = Process()
    let pipe = Pipe()
    
    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = ["-c", command]
    task.launchPath = "/bin/zsh"
    task.standardInput = nil

    do {
        try task.run()
    } catch {
        print("Error running command: \(error)")
        return nil
    }
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)
    
    return output
}