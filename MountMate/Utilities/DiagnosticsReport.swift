import AppKit
import Foundation
import OSLog

/// A text report users can paste into a bug report: app and macOS version,
/// on/off settings, disk and network share counts and the last hour of MountMate's own log. It never holds
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

  /// Counts about the saved network shares: no names, servers or paths.
  struct ShareSummary: Equatable {
    var savedByProtocol: [ShareProtocol: Int] = [:]
    var mounted = 0
    var keepAlive = 0
    var mountAtLogin = 0
    var almostFull = 0
    /// Shares not reconnected because the server rejected their password.
    var passwordRejected = 0
    /// Times Keep Alive found a mounted share not responding and reconnected
    /// it this session.
    var staleDetected = 0
    /// NFS shares mounted soft (they fail instead of hanging on a dead server).
    var nfsSoftMount = 0

    var saved: Int { savedByProtocol.values.reduce(0, +) }
  }

  /// Counts `shares`; `mountedIDs` and `usage` come from the share manager,
  /// `passwordRejectedIDs` from Keep Alive.
  static func shareSummary(
    of shares: [NetworkShare], mountedIDs: Set<UUID>, usage: [UUID: ShareUsage],
    threshold: Double?, passwordRejectedIDs: Set<UUID> = [], readOnlyIDs: Set<UUID> = []
  ) -> ShareSummary {
    var summary = ShareSummary()
    for share in shares {
      summary.savedByProtocol[share.shareProtocol, default: 0] += 1
      let isMounted = mountedIDs.contains(share.id)
      if isMounted { summary.mounted += 1 }
      if share.keepMounted { summary.keepAlive += 1 }
      if share.mountAtLogin { summary.mountAtLogin += 1 }
      if passwordRejectedIDs.contains(share.id) { summary.passwordRejected += 1 }
      if share.shareProtocol == .nfs && share.softMount { summary.nfsSoftMount += 1 }
      if isMounted, let shareUsage = usage[share.id],
        LowSpaceRules.warning(
          for: shareUsage, isReadOnly: share.readOnly || readOnlyIDs.contains(share.id),
          threshold: threshold) != nil
      {
        summary.almostFull += 1
      }
    }
    return summary
  }

  /// Counts about the listed disks: bus and file system names only.
  struct DiskSummary: Equatable {
    var disksByBus: [String: Int] = [:]
    var volumesByFileSystem: [String: Int] = [:]
  }

  /// Counts `disks` by bus (USB, Thunderbolt…) and their volumes by file
  /// system (the mounted one when known, else the partition's).
  static func diskSummary(of disks: [PhysicalDisk]) -> DiskSummary {
    var summary = DiskSummary()
    for disk in disks {
      let bus: String
      if disk.isRAIDSet {
        bus = "RAID"
      } else if disk.type == .diskImage {
        bus = "Disk Image"
      } else {
        bus = disk.connectionType.isEmpty ? "Unknown" : disk.connectionType
      }
      summary.disksByBus[bus, default: 0] += 1
      for volume in disk.allVolumes {
        let fileSystem = volume.mountedFileSystemType ?? volume.fileSystemType ?? ""
        summary.volumesByFileSystem[fileSystem.isEmpty ? "unknown" : fileSystem, default: 0] += 1
      }
    }
    return summary
  }

  /// "USB 2, apfs 1" sorted by name, or "none".
  static func countList(_ counts: [String: Int]) -> String {
    guard !counts.isEmpty else { return "none" }
    return counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
  }

  static let maxLines = 2000
  static let window: TimeInterval = 60 * 60

  /// Settings written to the report: the on/off switches only.
  static let flagKeys: [(name: String, key: String, defaultValue: Bool)] = [
    ("Keep Alive", "keepAliveEnabled", true),
    ("Keep Alive: remount on network change", "keepAliveRemountOnNetworkChange", true),
    ("Keep Alive: reconnect after sleep", "keepAliveRemountOnWake", true),
    ("Unmount all disks on sleep", "ejectOnSleepEnabled", false),
    ("Unmount all disks when the screen locks", ScreenLockRules.enabledKey, false),
    ("Mount again on wake", "remountOnWakeEnabled", true),
    ("Block USB auto-mount", "blockUSBAutoMount", false),
    ("Allow other apps to mount blocked disks", "allowRequestedMounts", false),
    ("Block at startup", "blockAtStartup", false),
    ("Notifications", "notificationsEnabled", false),
    (
      "Notify when a disk is disconnected without ejecting",
      UnexpectedRemovalTracker.enabledKey, false
    ),
    ("Open in Finder after mounting", "openFinderAfterMount", false),
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
  /// `mountPoints` are the saved shares' custom mount points; they are named
  /// after the share, so they are hidden wherever they appear.
  static func sanitize(
    _ text: String, homeDirectory: String = NSHomeDirectory(), mountPoints: [String] = []
  ) -> String {
    var result = text
    let hidesHome = homeDirectory.count > 1
    // Longest first, so a mount point inside another one is hidden whole.
    for mountPoint in mountPoints.sorted(by: { $0.count > $1.count }) {
      var forms = [mountPoint]
      if hidesHome, mountPoint.hasPrefix(homeDirectory + "/") {
        forms.append("~" + mountPoint.dropFirst(homeDirectory.count))
      }
      for form in forms where form.count > 1 {
        result = result.replacingOccurrences(of: form, with: "<mountpoint>")
      }
    }
    if hidesHome {
      result = result.replacingOccurrences(of: homeDirectory, with: "~")
    }
    let rules: [(pattern: String, template: String)] = [
      (#"/Users/[^/\s"']+"#, "/Users/<user>"),
      // Volume and share names may contain spaces, so the rest of the line goes.
      (#"/Volumes/[^\n]*"#, "/Volumes/<volume>"),
      // Default share mount points: ~/mountmate/<share name>.
      (#"(~|/Users/<user>)/mountmate/[^\n]*"#, "$1/mountmate/<share>"),
      (#"(?i)\b(smb|nfs|afp|cifs|ftp|webdav|https?)://[^\s"']+"#, "$1://<server>"),
    ]
    for rule in rules {
      result = result.replacingOccurrences(
        of: rule.pattern, with: rule.template, options: .regularExpression)
    }
    return result
  }

  /// The custom mount points of `shares`, as full paths.
  static func customMountPoints(
    of shares: [NetworkShare], homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    shares.compactMap { share in
      guard let custom = share.customMountPoint, !custom.isEmpty else { return nil }
      return NetworkMountTable.configuredMountPoint(for: share, homeDirectory: homeDirectory)
    }
  }

  static func format(
    appVersion: String,
    build: String,
    macOS: String,
    flags: [Flag],
    keepAliveInterval: Double? = nil,
    lowSpaceThreshold: Double? = nil,
    disks: DiskSummary = DiskSummary(),
    failingDiskCount: Int = 0,
    almostFullVolumeCount: Int = 0,
    lowSpaceMutedVolumeCount: Int = 0,
    duplicateUUIDVolumeCount: Int = 0,
    shares: ShareSummary = ShareSummary(),
    lines: [LogLine],
    generatedAt: Date,
    homeDirectory: String = NSHomeDirectory(),
    mountPoints: [String] = [],
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
    if let keepAliveInterval {
      out.append("  Keep Alive interval: \(Int(keepAliveInterval)) s")
    }
    out.append(
      "  Low-space warning threshold: "
        + (lowSpaceThreshold.map { "\(Int(($0 * 100).rounded())) %" } ?? "off"))
    out += [
      "", "Disks by bus: \(countList(disks.disksByBus))",
      "Volumes by file system: \(countList(disks.volumesByFileSystem))",
      "Disks reporting SMART failing: \(failingDiskCount)",
      "Volumes almost full: \(almostFullVolumeCount)",
      "Volumes with the free space warning off: \(lowSpaceMutedVolumeCount)",
      "Volumes sharing a UUID with another volume: \(duplicateUUIDVolumeCount)",
      "Previous /etc/fstab kept at: \(FstabWriter.backupPath())",
      "",
      "Network shares (saved): \(shares.saved)",
    ]
    let byProtocol = ShareProtocol.allCases.map {
      "\($0.displayName) \(shares.savedByProtocol[$0] ?? 0)"
    }
    out += [
      "  By protocol: \(byProtocol.joined(separator: ", "))",
      "  Mounted: \(shares.mounted)",
      "  Keep Alive: \(shares.keepAlive)",
      "  Mount at login: \(shares.mountAtLogin)",
      "  Almost full: \(shares.almostFull)",
      "  Password rejected: \(shares.passwordRejected)",
      "  Stale mounts detected: \(shares.staleDetected)",
      "  NFS soft mount: \(shares.nfsSoftMount)",
    ]
    out += [
      "",
      "Log, last hour (\(lines.count) \(lines.count == 1 ? "line" : "lines")):",
    ]
    if lines.isEmpty {
      out.append("  (no log entries)")
    }
    for line in lines {
      let message = sanitize(
        line.message, homeDirectory: homeDirectory, mountPoints: mountPoints)
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
  static func build(
    keepAliveInterval: Double? = nil, lowSpaceThreshold: Double? = nil,
    disks: DiskSummary = DiskSummary(),
    failingDiskCount: Int = 0, almostFullVolumeCount: Int = 0, lowSpaceMutedVolumeCount: Int = 0,
    duplicateUUIDVolumeCount: Int = 0,
    shares: ShareSummary = ShareSummary(), mountPoints: [String] = [], now: Date = Date()
  ) throws -> String {
    let info = Bundle.main.infoDictionary
    return format(
      appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
      build: info?["CFBundleVersion"] as? String ?? "?",
      macOS: ProcessInfo.processInfo.operatingSystemVersionString,
      flags: flags(),
      keepAliveInterval: keepAliveInterval,
      lowSpaceThreshold: lowSpaceThreshold,
      disks: disks,
      failingDiskCount: failingDiskCount,
      almostFullVolumeCount: almostFullVolumeCount,
      lowSpaceMutedVolumeCount: lowSpaceMutedVolumeCount,
      duplicateUUIDVolumeCount: duplicateUUIDVolumeCount,
      shares: shares,
      lines: try collectLogLines(now: now),
      generatedAt: now,
      mountPoints: mountPoints)
  }

  /// Builds the report in the background and puts it on the pasteboard.
  /// Returns false when the log could not be read.
  static func copyToPasteboard(
    keepAliveInterval: Double? = nil, lowSpaceThreshold: Double? = nil,
    disks: DiskSummary = DiskSummary(),
    failingDiskCount: Int = 0, almostFullVolumeCount: Int = 0, lowSpaceMutedVolumeCount: Int = 0,
    duplicateUUIDVolumeCount: Int = 0,
    shares: ShareSummary = ShareSummary(), mountPoints: [String] = []
  ) async -> Bool {
    let report = await Task.detached(priority: .userInitiated) { () -> String? in
      do {
        return try build(
          keepAliveInterval: keepAliveInterval, lowSpaceThreshold: lowSpaceThreshold,
          disks: disks,
          failingDiskCount: failingDiskCount, almostFullVolumeCount: almostFullVolumeCount,
          lowSpaceMutedVolumeCount: lowSpaceMutedVolumeCount,
          duplicateUUIDVolumeCount: duplicateUUIDVolumeCount, shares: shares,
          mountPoints: mountPoints)
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
