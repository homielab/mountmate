//  Created by homielab.com

import XCTest

@testable import MountMate

final class BlockedVolumeSweepTests: XCTestCase {
  private let info = ManagedVolumeInfo(
    volumeUUID: "12345678-1234-1234-1234-123456789ABC", diskUUID: "D1", name: "Backup")

  private let normalizedUUID = "12345678-1234-1234-1234-123456789ABC"

  /// An XML plist string like `diskutil info -plist` prints.
  private func plistXML(_ payload: [String: Any]) -> String {
    let data = try! PropertyListSerialization.data(
      fromPropertyList: payload, format: .xml, options: 0)
    return String(data: data, encoding: .utf8)!
  }

  /// A `diskutil list -plist` payload with the blocked volume as the only
  /// partition entry (plus `extra` volumes), on the blocked disk "D1".
  private func listXML(_ entry: [String: Any], extra: [[String: Any]] = []) -> String {
    var volume = entry
    volume["VolumeUUID"] = volume["VolumeUUID"] ?? normalizedUUID
    volume["DiskUUID"] = volume["DiskUUID"] ?? "D1"
    return plistXML([
      "AllDisksAndPartitions": [
        ["DeviceIdentifier": "disk1", "Partitions": [volume]],
        ["DeviceIdentifier": "disk9", "APFSVolumes": extra],
      ]
    ])
  }

  private func ok(_ stdout: String = "", _ stderr: String = "") -> ProcessResult {
    ProcessResult(stdout: stdout, stderr: stderr, exitCode: 0, timedOut: false)
  }

  private func failed(_ stderr: String = "") -> ProcessResult {
    ProcessResult(stdout: "", stderr: stderr, exitCode: 1, timedOut: false)
  }

  private struct Recorder {
    var commands: [(String, [String])] = []
    var sleeps: [TimeInterval] = []
    var notified: [(String, String)] = []
  }

  /// Runs the sweep with an in-memory runner for the two diskutil commands.
  private func runSweep(
    _ recorder: inout Recorder,
    infoOutput: @escaping () -> String,
    unmountResults: [ProcessResult]
  ) {
    var unmountCalls = 0
    BlockedVolumeSweep.run(
      infos: [info],
      run: { executable, arguments in
        recorder.commands.append((executable, arguments))
        if arguments.first == "list" {
          return ok(infoOutput())
        }
        defer { unmountCalls += 1 }
        return unmountCalls < unmountResults.count
          ? unmountResults[unmountCalls]
          : ProcessResult(stdout: "", stderr: "", exitCode: 1, timedOut: true)
      },
      sleep: { recorder.sleeps.append($0) },
      notify: { name, uuid in recorder.notified.append((name, uuid)) }
    )
  }

  // MARK: mountedDevice

  func testMountedDeviceReadsTheIdentifier() {
    let device = BlockedVolumeSweep.mountedDevice(
      in: ["DeviceIdentifier": "disk1s2", "MountPoint": "/Volumes/Backup"])
    XCTAssertEqual(device, "disk1s2")
  }

  func testEmptyOrNotMountedMountPointsAreSkipped() {
    XCTAssertNil(
      BlockedVolumeSweep.mountedDevice(
        in: ["DeviceIdentifier": "disk1s2", "MountPoint": ""]))
    XCTAssertNil(
      BlockedVolumeSweep.mountedDevice(
        in: ["DeviceIdentifier": "disk1s2", "MountPoint": "  "]))
    XCTAssertNil(
      BlockedVolumeSweep.mountedDevice(
        in: ["DeviceIdentifier": "disk1s2", "MountPoint": "Not Mounted"]))
    XCTAssertNil(
      BlockedVolumeSweep.mountedDevice(
        in: ["DeviceIdentifier": "disk1s2", "MountPoint": "not mounted"]))
  }

  // MARK: classify

  func testClassifyReadsTheOutcome() {
    XCTAssertEqual(BlockedVolumeSweep.classify(ok(), attempt: 1), .success)
    XCTAssertEqual(
      BlockedVolumeSweep.classify(ok("already unmounted"), attempt: 1),
      .success)
    XCTAssertEqual(
      BlockedVolumeSweep.classify(failed("not mounted"), attempt: 1),
      .alreadyUnmounted)
    XCTAssertEqual(
      BlockedVolumeSweep.classify(failed("Resource busy"), attempt: 1),
      .retryAfterSleep)
    XCTAssertEqual(
      BlockedVolumeSweep.classify(failed("Resource busy"), attempt: 3),
      .gaveUp)
  }

  // MARK: the sweep

  func testUnmountsOnTheFirstAttempt() {
    var recorder = Recorder()
    runSweep(
      &recorder,
      infoOutput: {
        self.listXML(["DeviceIdentifier": "disk1s2", "MountPoint": "/Volumes/Backup"])
      },
      unmountResults: [self.ok()])

    XCTAssertEqual(recorder.commands.count, 2)
    XCTAssertEqual(recorder.commands[1].1, ["unmount", "disk1s2"])
    XCTAssertTrue(recorder.sleeps.isEmpty, "a first-attempt success never sleeps")
    XCTAssertTrue(recorder.notified.isEmpty)
  }

  func testNotMountedVolumeIsSkippedWithoutUnmounting() {
    var recorder = Recorder()
    runSweep(
      &recorder,
      infoOutput: {
        self.listXML(["DeviceIdentifier": "disk1s2", "MountPoint": "Not Mounted"])
      },
      unmountResults: [])

    XCTAssertEqual(recorder.commands.count, 1, "only the list command runs")
    XCTAssertTrue(recorder.notified.isEmpty)
  }

  func testRetriesBusyVolumesAndNotifiesAfterTheLastAttempt() {
    var recorder = Recorder()
    runSweep(
      &recorder,
      infoOutput: {
        self.listXML(["DeviceIdentifier": "disk1s2", "MountPoint": "/Volumes/Backup"])
      },
      unmountResults: [
        self.failed("Resource busy"), self.failed("Resource busy"),
        self.failed("Resource busy"),
      ])

    // three attempts, two sleeps between them, one notification
    XCTAssertEqual(recorder.commands.count, 4)
    XCTAssertEqual(recorder.sleeps, [3.0, 3.0])
    XCTAssertEqual(recorder.notified.count, 1)
    XCTAssertEqual(recorder.notified.first?.0, "Backup")
    XCTAssertEqual(recorder.notified.first?.1, self.normalizedUUID)
  }

  func testSecondAttemptSuccessDoesNotNotify() {
    var recorder = Recorder()
    runSweep(
      &recorder,
      infoOutput: {
        self.listXML(["DeviceIdentifier": "disk1s2", "MountPoint": "/Volumes/Backup"])
      },
      unmountResults: [self.failed("Resource busy"), self.ok()])

    XCTAssertEqual(recorder.commands.count, 3)
    XCTAssertEqual(recorder.sleeps, [3.0])
    XCTAssertTrue(recorder.notified.isEmpty)
  }

  // MARK: targetDevice

  private func entry(
    _ device: String, uuid: String? = nil, disk: String? = "D1",
    mountPoint: String = "/Volumes/Backup"
  ) -> [String: Any] {
    var entry: [String: Any] = [
      "DeviceIdentifier": device, "VolumeUUID": uuid ?? normalizedUUID, "MountPoint": mountPoint,
    ]
    if let disk { entry["DiskUUID"] = disk }
    return entry
  }

  private func list(_ partitions: [[String: Any]], apfs: [[String: Any]] = []) -> [String: Any] {
    [
      "AllDisksAndPartitions": [
        ["DeviceIdentifier": "disk1", "Partitions": partitions],
        ["DeviceIdentifier": "disk5", "APFSVolumes": apfs],
      ]
    ]
  }

  func testTargetDeviceUsesTheOnlyMatchingVolume() {
    let plist = list([
      entry("disk1s2"), entry("disk1s3", uuid: "AAAAAAAA-1234-1234-1234-123456789ABC"),
    ])
    XCTAssertEqual(BlockedVolumeSweep.targetDevice(in: plist, for: info), "disk1s2")
  }

  func testTargetDeviceFindsAPFSVolumesAndIgnoresCase() {
    let plist = list([], apfs: [entry("disk5s1", uuid: normalizedUUID.lowercased(), disk: "d1")])
    XCTAssertEqual(BlockedVolumeSweep.targetDevice(in: plist, for: info), "disk5s1")
  }

  func testTwoVolumesSharingTheUUIDAreNeverUnmounted() {
    let plist = list([entry("disk1s2")], apfs: [entry("disk5s1", disk: "D2")])
    XCTAssertNil(BlockedVolumeSweep.targetDevice(in: plist, for: info))
  }

  func testVolumeOnAnotherDiskIsNotUnmounted() {
    let plist = list([entry("disk1s2", disk: "D2")])
    XCTAssertNil(BlockedVolumeSweep.targetDevice(in: plist, for: info))
  }

  func testNoneMatchesAVolumeWithoutDiskUUID() {
    let none = ManagedVolumeInfo(volumeUUID: normalizedUUID, diskUUID: "NONE", name: "Backup")
    XCTAssertEqual(
      BlockedVolumeSweep.targetDevice(in: list([entry("disk1s2", disk: nil)]), for: none),
      "disk1s2")
    XCTAssertNil(
      BlockedVolumeSweep.targetDevice(in: list([entry("disk1s2", disk: "D1")]), for: none))
    XCTAssertNil(
      BlockedVolumeSweep.targetDevice(in: list([entry("disk1s2", disk: nil)]), for: info))
  }

  func testTargetDeviceSkipsUnmountedAndMissingVolumes() {
    XCTAssertNil(
      BlockedVolumeSweep.targetDevice(
        in: list([entry("disk1s2", mountPoint: "Not Mounted")]), for: info))
    XCTAssertNil(BlockedVolumeSweep.targetDevice(in: list([]), for: info))
  }

  func testSweepLeavesClonedVolumesMounted() {
    var recorder = Recorder()
    runSweep(
      &recorder,
      infoOutput: {
        self.listXML(
          ["DeviceIdentifier": "disk1s2", "MountPoint": "/Volumes/Backup"],
          extra: [self.entry("disk5s1", disk: "D2")])
      },
      unmountResults: [])
    XCTAssertEqual(recorder.commands.count, 1, "no unmount for a shared UUID")
  }

  func testBrokenInfoOrUnknownUUIDSkipEverything() {
    var recorder = Recorder()
    runSweep(
      &recorder,
      infoOutput: { "not a plist" },
      unmountResults: [])
    XCTAssertEqual(recorder.commands.count, 1)

    var recorder2 = Recorder()
    let broken = ManagedVolumeInfo(volumeUUID: "nope", diskUUID: "D2", name: "X")
    BlockedVolumeSweep.run(
      infos: [broken],
      run: { _, _ in self.ok() },
      sleep: { recorder2.sleeps.append($0) },
      notify: { name, uuid in recorder2.notified.append((name, uuid)) }
    )
    XCTAssertTrue(recorder2.commands.isEmpty, "an invalid UUID runs nothing")
  }
}
