import AppKit
import Foundation
import OSLog

/// A text report users can paste into a bug report: app and macOS version,
/// on/off settings and the last hour of MountMate's own log. It never holds
/// paths, volume or share names, or passwords.
enum DiagnosticsReport {
  struct LogLine: Equatable {
    let date: Date
    let category: String
    let level: String
    let message: String
  }

  /// One on/off setting shown in the report header.
  struct Flag: Equatable {
    let name: String
    let isOn: Bool
  }

  static let maxLines = 2000
  static let window: TimeInterval = 60 * 60

  /// Settings written to the report: the on/off switches only.
  static let flagKeys: [(name: String, key: String, defaultValue: Bool)] = [
    ("Keep Alive", "keepAliveEnabled", true),
    ("Keep Alive: remount on network change", "keepAliveRemountOnNetworkChange", true),
    ("Keep Alive: reconnect after sleep", "keepAliveRemountOnWake", true),
    ("Unmount all disks on sleep", "ejectOnSleepEnabled", false),
    ("Mount again on wake", "remountOnWakeEnabled", true),
    ("Block USB auto-mount", "blockUSBAutoMount", false),
    ("Allow other apps to mount blocked disks", "allowRequestedMounts", false),
    ("Block at startup", "blockAtStartup", false),
    ("Notifications", "notificationsEnabled", false),
    ("Show internal disks", "showInternalDisks", false),
    ("Show only volumes", "showOnlyVolumes", false),
    ("Hide EFI partitions", "hideEFIPartitions", false),
    ("Keyboard shortcuts", "hotkeysEnabled", false),
    ("Count in menu bar", "showCountInMenuBar", false),
  ]

  static func flags(defaults: UserDefaults = .standard) -> [Flag] {
    flagKeys.map { item in
      let isOn =
        defaults.object(forKey: item.key) == nil
        ? item.defaultValue : defaults.bool(forKey: item.key)
      return Flag(name: item.name, isOn: isOn)
    }
  }

  // MARK: Formatting

  /// Removes what could identify the user or a drive from a log message.
  static func sanitize(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
    var result = text
    if homeDirectory.count > 1 {
      result = result.replacingOccurrences(of: homeDirectory, with: "~")
    }
    let rules: [(pattern: String, template: String)] = [
      (#"/Users/[^/\s"']+"#, "/Users/<user>"),
      // Volume names may contain spaces, so the rest of the line goes.
      (#"/Volumes/[^\n]*"#, "/Volumes/<volume>"),
      (#"(?i)\b(smb|nfs|afp|cifs|ftp|webdav|https?)://[^\s"']+"#, "$1://<server>"),
    ]
    for rule in rules {
      result = result.replacingOccurrences(
        of: rule.pattern, with: rule.template, options: .regularExpression)
    }
    return result
  }

  static func format(
    appVersion: String,
    build: String,
    macOS: String,
    flags: [Flag],
    lines: [LogLine],
    generatedAt: Date,
    homeDirectory: String = NSHomeDirectory(),
    timeZone: TimeZone = .current
  ) -> String {
    let stamp = ISO8601DateFormatter()
    stamp.timeZone = timeZone
    var out: [String] = [
      "MountMate diagnostics",
      "Generated: \(stamp.string(from: generatedAt))",
      "MountMate: \(appVersion) (\(build))",
      "macOS: \(macOS)",
      "",
      "Settings:",
    ]
    out += flags.map { "  \($0.name): \($0.isOn ? "on" : "off")" }
    out += [
      "",
      "Log, last hour (\(lines.count) \(lines.count == 1 ? "line" : "lines")):",
    ]
    if lines.isEmpty {
      out.append("  (no log entries)")
    }
    for line in lines {
      let message = sanitize(line.message, homeDirectory: homeDirectory)
      out.append("\(stamp.string(from: line.date)) [\(line.category)] \(line.level): \(message)")
    }
    return out.joined(separator: "\n") + "\n"
  }

  /// Keeps the newest `limit` lines, oldest first.
  static func newest(_ lines: [LogLine], limit: Int = maxLines) -> [LogLine] {
    let sorted = lines.sorted { $0.date < $1.date }
    return Array(sorted.suffix(limit))
  }

  // MARK: Collecting

  /// Reads this process's log entries of the last hour. Slow: call it off the
  /// main thread.
  static func collectLogLines(now: Date = Date()) throws -> [LogLine] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let position = store.position(date: now.addingTimeInterval(-window))
    let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
    let entries = try store.getEntries(at: position, matching: predicate)
    var lines: [LogLine] = []
    for case let entry as OSLogEntryLog in entries {
      lines.append(
        LogLine(
          date: entry.date, category: entry.category, level: levelName(entry.level),
          message: entry.composedMessage))
    }
    return newest(lines)
  }

  private static func levelName(_ level: OSLogEntryLog.Level) -> String {
    switch level {
    case .debug: return "debug"
    case .info: return "info"
    case .notice: return "notice"
    case .error: return "error"
    case .fault: return "fault"
    default: return "log"
    }
  }

  /// The whole report for this run. Slow: call it off the main thread.
  static func build(now: Date = Date()) throws -> String {
    let info = Bundle.main.infoDictionary
    return format(
      appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
      build: info?["CFBundleVersion"] as? String ?? "?",
      macOS: ProcessInfo.processInfo.operatingSystemVersionString,
      flags: flags(),
      lines: try collectLogLines(now: now),
      generatedAt: now)
  }

  /// Builds the report in the background and puts it on the pasteboard.
  /// Returns false when the log could not be read.
  static func copyToPasteboard() async -> Bool {
    let report = await Task.detached(priority: .userInitiated) { () -> String? in
      do {
        return try build()
      } catch {
        Log.app.error(
          "Could not build the diagnostics report: \(error.localizedDescription, privacy: .public)"
        )
        return nil
      }
    }.value
    guard let report else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(report, forType: .string)
  }
}
