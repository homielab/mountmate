import Foundation
import os

/// Unified-logging loggers, one per area. Read them with Console.app or
/// `log show --predicate 'subsystem == "com.homielab.mountmate"' --last 1h`.
///
/// Dynamic strings are private by default in os.Logger. Interpolate share
/// names, volume names, paths and error text with `privacy: .private`; only
/// identifiers, counts and status codes are `.public`. Never log a password,
/// a passphrase or an unredacted command line (use `redactedArguments`).
enum Log {
  static let subsystem = Bundle.main.bundleIdentifier ?? "com.homielab.mountmate"

  static let drive = Logger(subsystem: subsystem, category: "drive")
  static let keepAlive = Logger(subsystem: subsystem, category: "keepAlive")
  static let persistence = Logger(subsystem: subsystem, category: "persistence")
  static let network = Logger(subsystem: subsystem, category: "network")
  static let app = Logger(subsystem: subsystem, category: "app")
  static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
  static let mounter = Logger(subsystem: subsystem, category: "mounter")
  static let shell = Logger(subsystem: subsystem, category: "shell")
}
