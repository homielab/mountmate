//  Created by homielab.com

import XCTest

@testable import MountMate

final class BulkVolumeActionsTests: XCTestCase {
  private func volume(
    _ id: String, mounted: Bool = true, category: DriveCategory = .user, isProtected: Bool = false
  ) -> Volume {
    Volume(
      id: id, deviceIdentifier: "disk\(id)", diskUUID: nil, name: "Vol \(id)",
      isMounted: mounted, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: category,
      isProtected: isProtected, snapshots: [], storageError: nil)
  }

  private func disk(
    _ id: String, type: PhysicalDiskType = .physical, volumes: [Volume]
  ) -> PhysicalDisk {
    PhysicalDisk(
      id: id, diskUUID: nil, connectionType: "USB", name: id, totalSize: nil, freeSpace: nil,
      usedSpace: nil, usagePercentage: nil, type: type, isRAIDSet: false, partitions: volumes,
      containers: [], storageError: nil)
  }

  // MARK: - Candidates

  func testActionableDisksSkipInternalAndUnverifiedDisks() {
    let disks = [
      disk("disk2", volumes: []),
      disk("disk3", type: .internalDisk, volumes: []),
      disk("disk4", type: .diskImage, volumes: []),
      disk("disk5", volumes: []),
    ]
    let actionable = BulkVolumeActions.actionableDisks(disks, unverifiedDiskIDs: ["disk5"])
    XCTAssertEqual(actionable.map(\.id), ["disk2", "disk4"])
    XCTAssertEqual(BulkVolumeActions.actionableDisks(nil, unverifiedDiskIDs: []), [])
  }

  func testUnmountCandidatesAreMountedUserVolumesThatAreNotProtected() {
    let disks = [
      disk(
        "disk2",
        volumes: [
          volume("a"), volume("b", mounted: false), volume("c", category: .system),
          volume("d", isProtected: true), volume("e"),
        ])
    ]
    XCTAssertEqual(BulkVolumeActions.unmountCandidates(in: disks).map(\.id), ["a", "e"])
  }

  func testMountCandidatesSkipMountedSystemAndBlockedVolumes() {
    let disks = [
      disk(
        "disk2",
        volumes: [
          volume("a", mounted: false), volume("b"), volume("c", mounted: false, category: .system),
          volume("d", mounted: false), volume("e", mounted: false),
        ])
    ]
    let candidates = BulkVolumeActions.mountCandidates(in: disks) { $0.id == "d" }
    XCTAssertEqual(candidates.map(\.id), ["a", "e"])
  }

  // MARK: - Eject candidates

  func testEjectCandidatesAreExternalDisksCountedOnceWhateverTheirVolumes() {
    let disks = [
      disk("disk2", volumes: [volume("a"), volume("b")]),
      disk("disk3", type: .internalDisk, volumes: [volume("c")]),
      disk("disk4", type: .diskImage, volumes: [volume("d")]),
      disk("disk5", volumes: [volume("e", isProtected: true), volume("f")]),
      disk("disk6", volumes: [volume("g", mounted: false)]),
      disk("disk7", volumes: [volume("h")]),
    ]
    let candidates = BulkVolumeActions.ejectCandidates(in: disks, unverifiedDiskIDs: ["disk7"])
    // disk2 once (2 volumes), no internal disk, no disk image, no disk with
    // a protected volume, no unverified disk; an unmounted disk still ejects.
    XCTAssertEqual(candidates.map(\.id), ["disk2", "disk6"])
  }

  func testEjectCandidatesAreEmptyWithoutDisks() {
    XCTAssertEqual(BulkVolumeActions.ejectCandidates(in: [], unverifiedDiskIDs: []), [])
  }

  func testEjectArgumentsNeverForceAndUseUnmountDiskForRAIDSets() {
    let plain = disk("disk2", volumes: [])
    XCTAssertEqual(BulkVolumeActions.ejectArguments(for: plain), ["eject", "disk2"])
    let raid = PhysicalDisk(
      id: "disk9", diskUUID: nil, connectionType: "USB", name: "R", totalSize: nil, freeSpace: nil,
      usedSpace: nil, usagePercentage: nil, type: .physical, isRAIDSet: true, partitions: [],
      containers: [], storageError: nil)
    XCTAssertEqual(BulkVolumeActions.ejectArguments(for: raid), ["unmountDisk", "disk9"])
  }

  func testOneFailedEjectDoesNotStopTheOthersAndIsReportedOnce() {
    let disks = ["disk2", "disk3", "disk4", "disk5"].map { disk($0, volumes: []) }
    final class Seen: @unchecked Sendable {
      private let lock = NSLock()
      private var ids = Set<String>()
      func add(_ id: String) { lock.withLock { _ = ids.insert(id) } }
      var all: Set<String> { lock.withLock { ids } }
    }
    let seen = Seen()
    let failures = BulkVolumeActions.runConcurrently(disks) { disk in
      seen.add(disk.id)
      return disk.id != "disk3"
    }
    XCTAssertEqual(seen.all, ["disk2", "disk3", "disk4", "disk5"])
    XCTAssertEqual(failures.map(\.id), ["disk3"])
    let alert = BulkVolumeActions.failureAlert(
      forNames: failures.map { $0.name ?? $0.id }, title: "Eject Failed",
      format: "Could not eject: %@")
    XCTAssertEqual(alert?.message, "Could not eject: disk3")
  }

  func testSeveralFailedEjectsAreNamedInOneAlert() {
    let disks = ["disk2", "disk3", "disk4"].map { disk($0, volumes: []) }
    let failures = BulkVolumeActions.runConcurrently(disks) { $0.id == "disk3" }
    let alert = BulkVolumeActions.failureAlert(
      forNames: failures.map { $0.name ?? $0.id }, title: "Eject Failed",
      format: "Could not eject: %@")
    XCTAssertEqual(alert?.message, "Could not eject: disk2, disk4")
    XCTAssertNil(BulkVolumeActions.failureAlert(forNames: [], title: "T", format: "%@"))
  }

  // MARK: - Runner

  func testRunConcurrentlyReturnsNoFailuresWhenEveryRunnerSucceeds() {
    let volumes = (0..<12).map { volume("v\($0)") }
    final class Seen: @unchecked Sendable {
      private let lock = NSLock()
      private var ids = Set<String>()
      func add(_ id: String) { lock.withLock { _ = ids.insert(id) } }
      var count: Int { lock.withLock { ids.count } }
    }
    let seen = Seen()
    let failures = BulkVolumeActions.runConcurrently(volumes) { volume in
      seen.add(volume.id)
      return true
    }
    XCTAssertTrue(failures.isEmpty)
    XCTAssertEqual(seen.count, 12)
  }

  func testRunConcurrentlyReportsFailedVolumesInTheOriginalOrder() {
    let volumes = (0..<8).map { volume("v\($0)") }
    let failures = BulkVolumeActions.runConcurrently(volumes) { volume in
      !["v1", "v6"].contains(volume.id)
    }
    XCTAssertEqual(failures.map(\.id), ["v1", "v6"])
  }

  func testRunConcurrentlyWithNothingToDoReturnsNothing() {
    XCTAssertEqual(BulkVolumeActions.runConcurrently([Volume]()) { _ in false }, [])
  }

  func testRunConcurrentlyNeverExceedsOneRunnerPerCore() {
    final class Gauge: @unchecked Sendable {
      private let lock = NSLock()
      private var current = 0
      private(set) var peak = 0
      func enter() {
        lock.withLock {
          current += 1
          peak = max(peak, current)
        }
      }
      func leave() { lock.withLock { current -= 1 } }
      var maximum: Int { lock.withLock { peak } }
    }
    let gauge = Gauge()
    let volumes = (0..<40).map { volume("v\($0)") }
    _ = BulkVolumeActions.runConcurrently(volumes) { _ in
      gauge.enter()
      Thread.sleep(forTimeInterval: 0.01)
      gauge.leave()
      return true
    }
    XCTAssertLessThanOrEqual(gauge.maximum, ProcessInfo.processInfo.activeProcessorCount)
  }

  // MARK: - Alert

  func testFailureAlertNamesEveryFailedVolume() {
    let alert = BulkVolumeActions.failureAlert(
      for: [volume("1"), volume("2")], title: "Unmount Failed", format: "Could not unmount: %@")
    XCTAssertEqual(alert?.title, "Unmount Failed")
    XCTAssertEqual(alert?.message, "Could not unmount: Vol 1, Vol 2")
  }

  func testFailureAlertIsNilWithoutFailures() {
    XCTAssertNil(BulkVolumeActions.failureAlert(for: [], title: "T", format: "%@"))
  }

  // MARK: - Mount with retry

  private func result(_ code: Int32?, stderr: String = "") -> ProcessResult {
    ProcessResult(stdout: "", stderr: stderr, exitCode: code, timedOut: false)
  }

  private func runMount(
    _ results: [ProcessResult], retry: Bool
  ) -> (ok: Bool, attempts: Int, waits: Int, finished: Int) {
    var attempts = 0
    var waits = 0
    var finished = 0
    let ok = BulkVolumeActions.mountWithRetry(
      volume("1", mounted: false),
      attempt: { _ in
        defer { attempts += 1 }
        return results[min(attempts, results.count - 1)]
      },
      shouldRetry: { _, _ in retry }, wait: { waits += 1 }, didFinish: { _ in finished += 1 })
    return (ok, attempts, waits, finished)
  }

  func testMountWithRetryPostsFinishOnceWhenTheMountSucceeds() {
    let run = runMount([result(0)], retry: true)
    XCTAssertTrue(run.ok)
    XCTAssertEqual(run.attempts, 1)
    XCTAssertEqual(run.finished, 1)
  }

  func testMountWithRetryPostsFinishOnceEvenWhenTheMountFails() {
    let run = runMount([result(1)], retry: false)
    XCTAssertFalse(run.ok)
    XCTAssertEqual(run.attempts, 1)
    XCTAssertEqual(run.finished, 1)
  }

  func testMountWithRetryRetriesExactlyOnceForAFreshlyAppearedVolume() {
    let run = runMount([result(1), result(1), result(0)], retry: true)
    XCTAssertFalse(run.ok)
    XCTAssertEqual(run.attempts, 2)
    XCTAssertEqual(run.waits, 1)
    XCTAssertEqual(run.finished, 1)
  }

  func testMountWithRetrySucceedsWhenTheRetryWorks() {
    let run = runMount([result(1), result(0)], retry: true)
    XCTAssertTrue(run.ok)
    XCTAssertEqual(run.attempts, 2)
    XCTAssertEqual(run.finished, 1)
  }

  func testMountWithRetryDoesNotCountAnUnlockableVolumeAsAFailure() {
    let locked = result(1, stderr: "Volume is encrypted and locked")
    let run = runMount([locked], retry: false)
    XCTAssertEqual(run.finished, 1)
    XCTAssertEqual(run.ok, DiskUtilErrorClassifier.isLockedVolumeFailure(locked))
  }
}
