import XCTest

@testable import MountMate

final class TimeMachineDetectorTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("TimeMachineDetectorTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testHFSBackupFolderMarksVolume() throws {
    let backup = root.appendingPathComponent("Backup")
    try FileManager.default.createDirectory(
      at: backup.appendingPathComponent("Backups.backupdb"), withIntermediateDirectories: true)
    let plain = root.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    // Finder puts this on many external disks; it is not a backup marker.
    FileManager.default.createFile(
      atPath: plain.appendingPathComponent(".com.apple.timemachine.donotpresent").path,
      contents: nil)

    XCTAssertTrue(TimeMachineDetector.hasBackupMarker(atMountPoint: backup.path))
    XCTAssertFalse(TimeMachineDetector.hasBackupMarker(atMountPoint: plain.path))
    XCTAssertEqual(
      TimeMachineDetector.markedMountPoints([backup.path, plain.path]), [backup.path])
  }

  func testSupportedMarkerMarksVolume() {
    XCTAssertTrue(
      TimeMachineDetector.hasBackupMarker(atMountPoint: "/Volumes/TM") {
        $0 == "/Volumes/TM/.com.apple.timemachine.supported"
      })
  }

  func testSlowCheckCountsAsNotTimeMachine() {
    let start = Date()
    let found = TimeMachineDetector.markedMountPoints(
      ["/Volumes/Slow", "/Volumes/Fast"], timeout: 0.2
    ) { mountPoint in
      if mountPoint == "/Volumes/Slow" { Thread.sleep(forTimeInterval: 2) }
      return true
    }
    XCTAssertEqual(found, ["/Volumes/Fast"])
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
  }

  func testDestinationInfoParsesMountPoints() {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict><key>Destinations</key><array>
      <dict><key>ID</key><string>8F1C2A3B-0000-4000-8000-000000000001</string>
      <key>Kind</key><string>Local</string>
      <key>MountPoint</key><string>/Volumes/TM Backup</string>
      <key>Name</key><string>TM Backup</string></dict>
      <dict><key>ID</key><string>8F1C2A3B-0000-4000-8000-000000000002</string>
      <key>Kind</key><string>Network</string>
      <key>Name</key><string>NAS</string></dict>
      </array></dict></plist>
      """
    XCTAssertEqual(
      TimeMachineDetector.destinationMountPoints(fromDestinationInfo: Data(xml.utf8)),
      ["/Volumes/TM Backup"])
    XCTAssertEqual(TimeMachineDetector.destinationMountPoints(fromDestinationInfo: Data()), [])
  }

  func testOnlyVolumesUnderVolumesAreChecked() {
    let entries = [
      MountEntry(source: "/dev/disk3s1", mountPoint: "/", fileSystemType: "apfs"),
      MountEntry(source: "/dev/disk6s2", mountPoint: "/Volumes/Backup", fileSystemType: "hfs"),
    ]
    XCTAssertEqual(TimeMachineDetector.candidateMountPoints(in: entries), ["/Volumes/Backup"])
  }

  func testDestinationsReloadOnlyWhenMountedVolumesChange() {
    let cache = TimeMachineDetector.DestinationCache()
    var loads = 0
    let load = { () -> Set<String> in
      loads += 1
      return ["/Volumes/TM"]
    }
    XCTAssertEqual(cache.mountPoints(for: ["/Volumes/TM"], load: load), ["/Volumes/TM"])
    _ = cache.mountPoints(for: ["/Volumes/TM"], load: load)
    XCTAssertEqual(loads, 1)
    _ = cache.mountPoints(for: ["/Volumes/TM", "/Volumes/USB"], load: load)
    XCTAssertEqual(loads, 2)
  }
}
