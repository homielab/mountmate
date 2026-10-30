import XCTest

@testable import MountMate

final class DiagnosticsReportTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC")!
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func line(_ offset: TimeInterval, _ message: String, category: String = "drive")
    -> DiagnosticsReport.LogLine
  {
    .init(date: now.addingTimeInterval(offset), category: category, level: "info", message: message)
  }

  func testReportHasHeaderSettingsAndLog() {
    let report = DiagnosticsReport.format(
      appVersion: "6.4", build: "70", macOS: "Version 15.1",
      flags: [.init(name: "Keep Alive", isOn: true), .init(name: "Notifications", isOn: false)],
      failingDiskCount: 2, almostFullVolumeCount: 3,
      lines: [line(-60, "Refreshed 3 disks")], generatedAt: now, timeZone: utc)
    XCTAssertTrue(report.hasPrefix("MountMate diagnostics\n"))
    XCTAssertTrue(report.contains("MountMate: 6.4 (70)"))
    XCTAssertTrue(report.contains("macOS: Version 15.1"))
    XCTAssertTrue(report.contains("  Keep Alive: on"))
    XCTAssertTrue(report.contains("  Notifications: off"))
    XCTAssertTrue(report.contains("Disks reporting SMART failing: 2"))
    XCTAssertTrue(report.contains("Volumes almost full: 3"))
    XCTAssertTrue(report.contains("Log, last hour (1 line):"))
    XCTAssertTrue(report.contains("[drive] info: Refreshed 3 disks"))
  }

  func testEmptyLogIsSaidSo() {
    let report = DiagnosticsReport.format(
      appVersion: "1", build: "1", macOS: "x", flags: [], lines: [], generatedAt: now,
      timeZone: utc)
    XCTAssertTrue(report.contains("(no log entries)"))
  }

  func testSanitizeRemovesPathsVolumesAndServers() {
    let text =
      "opened /Users/alice/Documents via smb://nas.local/share, then /Volumes/My Secret/x"
    let result = DiagnosticsReport.sanitize(text, homeDirectory: "/Users/alice")
    XCTAssertFalse(result.contains("alice"))
    XCTAssertFalse(result.contains("Secret"))
    XCTAssertFalse(result.contains("nas.local"))
    XCTAssertTrue(result.contains("smb://<server>"))
  }

  func testSanitizeHidesDefaultShareMountPoints() {
    let text = "Mounted at /Users/alice/mountmate/My NAS (smb)"
    let result = DiagnosticsReport.sanitize(text, homeDirectory: "/Users/alice")
    XCTAssertEqual(result, "Mounted at ~/mountmate/<share>")
    let tilde = DiagnosticsReport.sanitize("Opened ~/mountmate/My NAS", homeDirectory: "/")
    XCTAssertEqual(tilde, "Opened ~/mountmate/<share>")
    let otherUser = DiagnosticsReport.sanitize(
      "Mounted at /Users/bob/mountmate/Bob Share", homeDirectory: "/Users/alice")
    XCTAssertEqual(otherUser, "Mounted at /Users/<user>/mountmate/<share>")
  }

  func testSanitizeHidesCustomMountPoints() {
    let mountPoints = ["/Users/alice/Shares/Family Photos", "/mnt/Media Box"]
    let text =
      "Mounted at /Users/alice/Shares/Family Photos; ~/Shares/Family Photos busy; /mnt/Media Box ok"
    let result = DiagnosticsReport.sanitize(
      text, homeDirectory: "/Users/alice", mountPoints: mountPoints)
    XCTAssertEqual(result, "Mounted at <mountpoint>; <mountpoint> busy; <mountpoint> ok")
  }

  func testCustomMountPointsAreFullPathsOfSharesWithOne() {
    let shares = [
      NetworkShare(name: "NAS", server: "nas.local", sharePath: "media", username: ""),
      NetworkShare(
        name: "Photos", server: "nas.local", sharePath: "photos", username: "",
        customMountPoint: "Shares/Photos"),
      NetworkShare(
        name: "Box", server: "box.local", sharePath: "b", username: "",
        customMountPoint: "~/Box Mount"),
    ]
    XCTAssertEqual(
      DiagnosticsReport.customMountPoints(of: shares, homeDirectory: "/Users/alice"),
      ["/Users/alice/Shares/Photos", NSHomeDirectory() + "/Box Mount"])
  }

  func testSampleReportHasNoShareNames() {
    let shareName = "Family Photos"
    let shares = [
      NetworkShare(name: "My NAS", server: "nas.local", sharePath: "media", username: ""),
      NetworkShare(
        name: shareName, server: "nas.local", sharePath: "photos", username: "",
        customMountPoint: "/Users/alice/Shares/\(shareName)"),
    ]
    let report = DiagnosticsReport.format(
      appVersion: "1", build: "1", macOS: "x", flags: [],
      lines: [
        line(-30, "Mounting smb://nas.local/media at /Users/alice/mountmate/My NAS"),
        line(-20, "Created /Users/alice/Shares/Family Photos"),
        line(-10, "Unmounted ~/Shares/Family Photos"),
      ],
      generatedAt: now, homeDirectory: "/Users/alice",
      mountPoints: DiagnosticsReport.customMountPoints(of: shares, homeDirectory: "/Users/alice"),
      timeZone: utc)
    XCTAssertFalse(report.contains("My NAS"))
    XCTAssertFalse(report.contains("Family"))
    XCTAssertFalse(report.contains("alice"))
    XCTAssertTrue(report.contains("~/mountmate/<share>"))
    XCTAssertTrue(report.contains("Created <mountpoint>"))
  }

  func testReportKeepsPrivateMarkerAndDropsHome() {
    let report = DiagnosticsReport.format(
      appVersion: "1", build: "1", macOS: "x", flags: [],
      lines: [line(0, "Unmount <private> failed at /Users/bob/Library")],
      generatedAt: now, homeDirectory: "/Users/bob", timeZone: utc)
    XCTAssertTrue(report.contains("<private>"))
    XCTAssertFalse(report.contains("bob"))
  }

  func testNewestKeepsLastLinesInOrder() {
    let lines = (0..<5).map { line(TimeInterval($0), "m\($0)") }.reversed()
    let kept = DiagnosticsReport.newest(Array(lines), limit: 3)
    XCTAssertEqual(kept.map(\.message), ["m2", "m3", "m4"])
  }

  func testFlagsUseDefaultsWhenUnset() {
    let suite = "DiagnosticsReportTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "keepAliveEnabled")
    defaults.set(true, forKey: "notificationsEnabled")
    let flags = DiagnosticsReport.flags(defaults: defaults)
    XCTAssertEqual(flags.first { $0.name == "Keep Alive" }?.isOn, false)
    XCTAssertEqual(flags.first { $0.name == "Notifications" }?.isOn, true)
    XCTAssertEqual(flags.first { $0.name == "Keep Alive: reconnect after sleep" }?.isOn, true)
    XCTAssertEqual(flags.first { $0.name == "Block at startup" }?.isOn, false)
  }

  func testFlagsListHasNoFreeTextSettings() {
    // Only on/off switches belong in the report.
    XCTAssertEqual(DiagnosticsReport.flagKeys.count, 17)
  }

  func testShareSummaryCountsSavedShares() {
    let mounted = NetworkShare(
      name: "Family Photos", server: "nas.local", sharePath: "photos", username: "alice")
    let idle = NetworkShare(
      name: "Backup", server: "10.0.0.5", sharePath: "/export/backup", username: "",
      mountAtLogin: false, keepMounted: false, shareProtocol: .nfs)
    let full = NetworkShare(
      name: "Media", server: "nas.local", sharePath: "media", username: "", mountAtLogin: false)
    let tb: Int64 = 1_000_000_000_000
    var summary = DiagnosticsReport.shareSummary(
      of: [mounted, idle, full], mountedIDs: [mounted.id, full.id],
      usage: [
        mounted.id: ShareUsage(totalBytes: tb, freeBytes: tb / 2),
        full.id: ShareUsage(totalBytes: tb, freeBytes: tb / 100),
        idle.id: ShareUsage(totalBytes: tb, freeBytes: 0),
      ],
      threshold: 0.9, passwordRejectedIDs: [idle.id, UUID()])
    XCTAssertEqual(summary.savedByProtocol, [.smb: 2, .nfs: 1])
    XCTAssertEqual(summary.saved, 3)
    XCTAssertEqual(summary.mounted, 2)
    XCTAssertEqual(summary.keepAlive, 2)
    XCTAssertEqual(summary.mountAtLogin, 1)
    XCTAssertEqual(summary.almostFull, 1)
    let readOnly = DiagnosticsReport.shareSummary(
      of: [mounted, idle, full], mountedIDs: [mounted.id, full.id],
      usage: [full.id: ShareUsage(totalBytes: tb, freeBytes: tb / 100)],
      threshold: 0.9, readOnlyIDs: [full.id])
    XCTAssertEqual(readOnly.almostFull, 0, "a read-only share is never almost full")
    XCTAssertEqual(summary.passwordRejected, 1, "deleted shares are not counted")
    summary.staleDetected = 3

    let report = DiagnosticsReport.format(
      appVersion: "1", build: "1", macOS: "x", flags: [], shares: summary, lines: [],
      generatedAt: now, timeZone: utc)
    XCTAssertTrue(report.contains("Network shares (saved): 3\n"))
    XCTAssertTrue(report.contains("  By protocol: SMB 2, NFS 1, AFP 0\n"))
    XCTAssertTrue(report.contains("  Mounted: 2\n"))
    XCTAssertTrue(report.contains("  Keep Alive: 2\n"))
    XCTAssertTrue(report.contains("  Mount at login: 1\n"))
    XCTAssertTrue(report.contains("  Almost full: 1\n"))
    XCTAssertTrue(report.contains("  Password rejected: 1\n"))
    XCTAssertTrue(report.contains("  Stale mounts detected: 3\n"))
    for secret in ["Family", "Backup", "Media", "nas.local", "10.0.0.5", "photos", "alice"] {
      XCTAssertFalse(report.contains(secret), secret)
    }
  }

  func testReportWithoutSharesSaysZero() {
    let report = DiagnosticsReport.format(
      appVersion: "1", build: "1", macOS: "x", flags: [], lines: [], generatedAt: now,
      timeZone: utc)
    XCTAssertTrue(report.contains("Network shares (saved): 0\n"))
    XCTAssertTrue(report.contains("  Stale mounts detected: 0\n"))
  }
}
