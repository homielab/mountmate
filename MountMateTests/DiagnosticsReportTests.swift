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
      lines: [line(-60, "Refreshed 3 disks")], generatedAt: now, timeZone: utc)
    XCTAssertTrue(report.hasPrefix("MountMate diagnostics\n"))
    XCTAssertTrue(report.contains("MountMate: 6.4 (70)"))
    XCTAssertTrue(report.contains("macOS: Version 15.1"))
    XCTAssertTrue(report.contains("  Keep Alive: on"))
    XCTAssertTrue(report.contains("  Notifications: off"))
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
    XCTAssertEqual(DiagnosticsReport.flagKeys.count, 14)
  }
}
