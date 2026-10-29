//  Created by homielab.com

import XCTest

@testable import MountMate

final class UnexpectedRemovalTrackerTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_000_000)

  private func volume(
    _ id: String = "VOL-1", name: String = "Backup", mountPoint: String? = "/Volumes/Backup",
    category: DriveCategory = .user, isTimeMachine: Bool = false
  ) -> Volume {
    Volume(
      id: id, deviceIdentifier: "disk4s1", diskUUID: nil, name: name,
      isMounted: mountPoint != nil, mountPoint: mountPoint, freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: nil, fileSystemType: "ExFAT", usagePercentage: nil,
      category: category, isProtected: false, snapshots: [], storageError: nil,
      isTimeMachine: isTimeMachine)
  }

  private func disk(
    _ id: String = "disk4", type: PhysicalDiskType = .physical, volumes: [Volume]
  ) -> PhysicalDisk {
    PhysicalDisk(
      id: id, diskUUID: nil, connectionType: "USB", name: "Card", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: type, isRAIDSet: false,
      partitions: volumes, containers: [])
  }

  /// Watches `disks`, then reports what vanished in a list without them.
  private func removalsAfterPulling(
    _ disks: [PhysicalDisk], tracker: inout UnexpectedRemovalTracker,
    ejectingDiskIDs: Set<String> = [], busyVolumeIDs: Set<String> = [],
    mountedPaths: Set<String>? = [], at time: TimeInterval = 1
  ) -> [UnexpectedRemovalTracker.Removal] {
    XCTAssertEqual(tracker.removals(in: disks, mountedPaths: [], now: start), [])
    return tracker.removals(
      in: [], ejectingDiskIDs: ejectingDiskIDs, busyVolumeIDs: busyVolumeIDs,
      mountedPaths: mountedPaths, now: start.addingTimeInterval(time))
  }

  func testMountedExternalVolumeThatVanishesIsReportedOnce() {
    var tracker = UnexpectedRemovalTracker()
    let removals = removalsAfterPulling([disk(volumes: [volume()])], tracker: &tracker)
    XCTAssertEqual(
      removals,
      [.init(volumeID: "VOL-1", name: "Backup", mountPoint: "/Volumes/Backup")])
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(2)), [])
  }

  func testEveryVolumeOfAPulledDiskIsReportedByName() {
    var tracker = UnexpectedRemovalTracker()
    let volumes = [
      volume("B", name: "Photos", mountPoint: "/Volumes/Photos"),
      volume("A", name: "Backup", mountPoint: "/Volumes/Backup"),
    ]
    let removals = removalsAfterPulling([disk(volumes: volumes)], tracker: &tracker)
    XCTAssertEqual(removals.map(\.name), ["Backup", "Photos"])
  }

  func testVolumeUnmountedFirstIsNotReported() {
    var tracker = UnexpectedRemovalTracker()
    _ = tracker.removals(in: [disk(volumes: [volume()])], mountedPaths: [], now: start)
    // Unmounted but still listed, then the disk is pulled.
    XCTAssertEqual(
      tracker.removals(
        in: [disk(volumes: [volume(mountPoint: nil)])], mountedPaths: [],
        now: start.addingTimeInterval(1)), [])
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(2)), [])
  }

  func testRequestedUnmountExplainsTheVanishingWithinItsMemory() {
    var tracker = UnexpectedRemovalTracker()
    _ = tracker.removals(in: [disk(volumes: [volume()])], mountedPaths: [], now: start)
    // Finder ejects inside the refresh debounce: the volume is never seen
    // unmounted, only the request is.
    tracker.recordRequestedUnmount(mountPoint: "/Volumes/Backup/", at: start)
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(1)), [])
  }

  func testOldUnmountRequestDoesNotHideALaterPull() {
    var tracker = UnexpectedRemovalTracker()
    tracker.recordRequestedUnmount(mountPoint: "/Volumes/Backup", at: start)
    _ = tracker.removals(in: [disk(volumes: [volume()])], mountedPaths: [], now: start)
    let later = start.addingTimeInterval(UnexpectedRemovalTracker.requestedUnmountMemory + 1)
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: later).map(\.name), ["Backup"])
  }

  func testUnmountRequestOfAnotherVolumeDoesNotHideAPull() {
    var tracker = UnexpectedRemovalTracker()
    _ = tracker.removals(in: [disk(volumes: [volume()])], mountedPaths: [], now: start)
    tracker.recordRequestedUnmount(mountPoint: "/Volumes/Other", at: start)
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(1)).count, 1)
  }

  func testMountMateEjectOrUnmountInFlightIsNotReported() {
    var ejecting = UnexpectedRemovalTracker()
    XCTAssertEqual(
      removalsAfterPulling(
        [disk(volumes: [volume()])], tracker: &ejecting, ejectingDiskIDs: ["disk4"]), [])
    var unmounting = UnexpectedRemovalTracker()
    XCTAssertEqual(
      removalsAfterPulling(
        [disk(volumes: [volume()])], tracker: &unmounting, busyVolumeIDs: ["VOL-1"]), [])
  }

  func testDiskImageInternalDiskSystemAndTimeMachineVolumesAreNotWatched() {
    let cases: [PhysicalDisk] = [
      disk(type: .diskImage, volumes: [volume()]),
      disk(type: .internalDisk, volumes: [volume()]),
      disk(volumes: [volume(category: .system)]),
      disk(volumes: [volume(isTimeMachine: true)]),
    ]
    for pulled in cases {
      var tracker = UnexpectedRemovalTracker()
      XCTAssertEqual(removalsAfterPulling([pulled], tracker: &tracker), [], "\(pulled.type)")
    }
  }

  func testUnverifiedDiskIsNotWatched() {
    var tracker = UnexpectedRemovalTracker()
    _ = tracker.removals(
      in: [disk(volumes: [volume()])], unverifiedDiskIDs: ["disk4"], mountedPaths: [],
      now: start)
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(1)), [])
  }

  func testVolumeStillInTheMountTableIsKeptAndReportedOnceItIsGone() {
    var tracker = UnexpectedRemovalTracker()
    // Hidden from the list (or not torn down yet) but still mounted.
    XCTAssertEqual(
      removalsAfterPulling(
        [disk(volumes: [volume()])], tracker: &tracker, mountedPaths: ["/Volumes/Backup"]),
      [])
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(2)).count, 1)
  }

  func testUnreadableMountTableReportsNothingYet() {
    var tracker = UnexpectedRemovalTracker()
    XCTAssertEqual(
      removalsAfterPulling([disk(volumes: [volume()])], tracker: &tracker, mountedPaths: nil),
      [])
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(2)).count, 1)
  }

  func testNothingIsReportedWhileAsleepOrRightAfterWake() {
    var tracker = UnexpectedRemovalTracker()
    _ = tracker.removals(in: [disk(volumes: [volume()])], mountedPaths: [], now: start)
    tracker.systemWillSleep()
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(1)), [])

    // Plugged in again after wake, then re-enumerated during the quiet period.
    tracker.systemDidWake(at: start.addingTimeInterval(100))
    _ = tracker.removals(
      in: [disk(volumes: [volume()])], mountedPaths: [], now: start.addingTimeInterval(101))
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(102)), [])

    // After the quiet period a pull is reported again.
    let later = start.addingTimeInterval(100 + UnexpectedRemovalTracker.wakeQuietPeriod + 1)
    _ = tracker.removals(in: [disk(volumes: [volume()])], mountedPaths: [], now: later)
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: later.addingTimeInterval(1)).count, 1)
  }

  func testResetForgetsWatchedVolumes() {
    var tracker = UnexpectedRemovalTracker()
    _ = tracker.removals(in: [disk(volumes: [volume()])], mountedPaths: [], now: start)
    tracker.reset()
    XCTAssertEqual(
      tracker.removals(in: [], mountedPaths: [], now: start.addingTimeInterval(1)), [])
  }

  func testIsOffByDefault() {
    let suiteName = "UnexpectedRemovalTrackerTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    XCTAssertFalse(UnexpectedRemovalTracker.isEnabled(defaults: defaults))
    defaults.set(true, forKey: UnexpectedRemovalTracker.enabledKey)
    XCTAssertTrue(UnexpectedRemovalTracker.isEnabled(defaults: defaults))
  }

  func testTimeMachineMountPointsAreRecognized() {
    XCTAssertTrue(
      DiskTopology.isTimeMachineVolume([
        "MountPoint": "/Volumes/.timemachine/ABC/2026-10-29-120000.backup"
      ]))
    XCTAssertFalse(DiskTopology.isTimeMachineVolume(["MountPoint": "/Volumes/Backup"]))
  }
}
