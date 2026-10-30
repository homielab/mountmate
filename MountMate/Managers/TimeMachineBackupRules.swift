//  Created by homielab.com

import Foundation

/// Decides whether a manual unmount or eject would cut off a running Time
/// Machine backup, from the output of `tmutil status`.
enum TimeMachineBackupRules {
  struct Status: Equatable, Sendable {
    var isRunning: Bool
    /// The destination being written, when `tmutil` names it.
    var destinationMountPoint: String?
  }

  /// Parses `tmutil status` ("Running = 1;", "DestinationMountPoint = …;").
  static func status(fromTmutilStatus output: String) -> Status {
    var status = Status(isRunning: false, destinationMountPoint: nil)
    for line in output.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: .whitespaces)
      var value = parts[1].trimmingCharacters(in: .whitespaces)
      if value.hasSuffix(";") { value.removeLast() }
      value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
      switch key {
      case "Running": status.isRunning = value == "1"
      case "DestinationMountPoint": status.destinationMountPoint = value.isEmpty ? nil : value
      default: break
      }
    }
    return status
  }

  /// The Time Machine volumes among `volumes` that a running backup is
  /// writing to. When `tmutil` does not name the destination, every mounted
  /// Time Machine volume counts, so the user is asked rather than surprised.
  static func volumesBeingBackedUp(_ volumes: [Volume], status: Status) -> [Volume] {
    guard status.isRunning else { return [] }
    let timeMachine = volumes.filter { $0.isTimeMachine && $0.isMounted }
    guard let destination = status.destinationMountPoint else { return timeMachine }
    return timeMachine.filter { $0.mountPoint == destination }
  }
}
