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

  func testEjectCandidatesSkipDisksAlreadyEjectingOrWithABusyVolume() {
    let disks = [
      disk("disk2", volumes: [volume("a")]),
      disk("disk3", volumes: [volume("b"), volume("c")]),
      disk("disk4", volumes: [volume("d")]),
    ]
    let candidates = BulkVolumeActions.ejectCandidates(
      in: disks, unverifiedDiskIDs: [], ejectingDiskIDs: ["disk2"], busyVolumeIDs: ["c"])
    // A second Eject All while the first runs leaves disk2 to the first;
    // disk3 waits until its volume's mount or unmount is done.
    XCTAssertEqual(candidates.map(\.id), ["disk4"])
  }

  func testEjectStartsOnlyWhenTheSameDiskIsNotEjectingAlready() {
    let target = disk("disk2", volumes: [volume("a")])
    XCTAssertTrue(BulkVolumeActions.canStartEject(of: target, ejectingDiskIDs: []))
    XCTAssertTrue(BulkVolumeActions.canStartEject(of: target, ejectingDiskIDs: ["disk3"]))
    XCTAssertFalse(BulkVolumeActions.canStartEject(of: target, ejectingDiskIDs: ["disk2"]))
  }

  /// A second Eject of a disk that is still ejecting does nothing: the
  /// first keeps its spinner and Keep Alive is not suppressed a second time
  /// (whose failure would otherwise keep the suppression for good).
  @MainActor
  func testSecondEjectOfADiskStillEjectingIsIgnored() throws {
    let manager = DriveManager.shared
    let target = disk(
      "disk-eject-twice-test",
      volumes: [
        // A UUID id, so the volume has a Keep Alive key (`compositeId`).
        volume("7E57E1EC-7000-4000-8000-0000000E7EC7")
      ])
    let key = try XCTUnwrap(target.allVolumes.first?.compositeId)
    manager.setEjecting(target.id, true)
    defer { manager.setEjecting(target.id, false) }

    XCTAssertFalse(manager.startEjectIfIdle(target))
    manager.eject(disk: target)
    manager.forceEject(disk: target)

    XCTAssertTrue(manager.isEjecting(target.id))
    XCTAssertFalse(KeepAliveManager.shared.isSuppressed(volumeID: key))
  }

  /// Refused ejects report through `completion` exactly once and, with
  /// `allowsErrorAlerts: false`, raise no alert.
  @MainActor
  func testRefusedEjectCallsCompletionOnceWithoutAlert() {
    let manager = DriveManager.shared
    let target = disk("disk-eject-completion-test", volumes: [])
    manager.setEjecting(target.id, true)
    defer { manager.setEjecting(target.id, false) }
    manager.userActionError = nil

    var results: [Result<Void, Error>] = []
    manager.eject(disk: target, allowsErrorAlerts: false) { results.append($0) }

    XCTAssertEqual(results.count, 1)
    if case .success = results[0] { XCTFail("an ignored eject must not succeed") }
    XCTAssertNil(manager.userActionError)
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

  func testFailureAlertListsReasonsUnderTheNamesAndKeepsItsKind() {
    let alert = BulkVolumeActions.failureAlert(
      forNames: ["A", "B"], title: "Eject Failed", format: "Could not eject: %@",
      reasons: ["“A” is busy.", "“B” timed out."], kind: .forceUnmount {})
    XCTAssertEqual(alert?.message, "Could not eject: A, B\n\n“A” is busy.\n“B” timed out.")
    guard case .forceUnmount = alert?.kind else { return XCTFail("expected Force Unmount") }
  }

  func testEjectTimeoutLeavesASleepingDiskTimeToWake() {
    XCTAssertEqual(BulkVolumeActions.ejectTimeout, 60)
    XCTAssertGreaterThan(BulkVolumeActions.ejectTimeout, DriveManager.mountUnmountTimeout)
  }

  func testMapConcurrentlyKeepsTheOriginalOrder() {
    XCTAssertEqual(
      BulkVolumeActions.mapConcurrently(Array(0..<20)) { $0 * 2 }, (0..<20).map { $0 * 2 })
  }

  // MARK: - Eject with retry

  private func ejectResult(_ code: Int32?, stderr: String = "", timedOut: Bool = false)
    -> ProcessResult
  {
    ProcessResult(stdout: "", stderr: stderr, exitCode: code, timedOut: timedOut)
  }

  private func runEject(_ results: [ProcessResult]) -> (
    result: ProcessResult, runs: Int, waits: Int
  ) {
    var runs = 0
    var waits = 0
    let result = BulkVolumeActions.ejectWithRetry(
      disk("disk2", volumes: []),
      run: { _ in
        defer { runs += 1 }
        return results[min(runs, results.count - 1)]
      }, wait: { waits += 1 })
    return (result, runs, waits)
  }

  func testEjectWithRetryRunsOnceWhenItSucceeds() {
    let run = runEject([ejectResult(0)])
    XCTAssertTrue(run.result.succeeded)
    XCTAssertEqual(run.runs, 1)
    XCTAssertEqual(run.waits, 0)
  }

  func testEjectWithRetryRunsASecondTimeAfterAPlainFailure() {
    let run = runEject([ejectResult(1, stderr: "Could not eject"), ejectResult(0)])
    XCTAssertTrue(run.result.succeeded)
    XCTAssertEqual(run.runs, 2)
    XCTAssertEqual(run.waits, 1)
  }

  func testEjectWithRetryReturnsTheSecondFailure() {
    let run = runEject([ejectResult(1, stderr: "first"), ejectResult(1, stderr: "second")])
    XCTAssertEqual(run.result.stderr, "second")
    XCTAssertEqual(run.runs, 2)
  }

  func testEjectWithRetryDoesNotRetryABusyDisk() {
    let run = runEject([ejectResult(1, stderr: "Volume is busy (dissented by PID 12 (/bin/x))")])
    XCTAssertFalse(run.result.succeeded)
    XCTAssertEqual(run.runs, 1)
    XCTAssertEqual(run.waits, 0)
  }

  func testEjectWithRetryDoesNotRetryATimeout() {
    let run = runEject([ejectResult(nil, timedOut: true)])
    XCTAssertEqual(run.runs, 1)
    XCTAssertEqual(run.waits, 0)
  }

  func testEjectDisksReportsEachFailedDiskWithItsReason() {
    let disks = [
      disk("disk2", volumes: []), disk("disk3", volumes: []), disk("disk4", volumes: []),
    ]
    let failures = BulkVolumeActions.ejectDisks(
      disks,
      run: { disk in
        switch disk.id {
        case "disk2": return self.ejectResult(0)
        case "disk3": return self.ejectResult(1, stderr: "Volume is busy")
        default: return self.ejectResult(1, stderr: "Some error")
        }
      }, wait: {})
    XCTAssertEqual(failures.map(\.name), ["disk3", "disk4"])
    XCTAssertEqual(failures.map(\.canForce), [true, false])
    XCTAssertTrue(failures[0].reason.contains("disk3"))
    XCTAssertTrue(failures[1].reason.contains("Some error"))
  }

  func testEjectFailureReasonForATimeoutCanBeForced() {
    let why = BulkVolumeActions.ejectFailureReason(
      for: ejectResult(nil, timedOut: true), name: "HDD")
    XCTAssertTrue(why.reason.contains("HDD"))
    XCTAssertTrue(why.canForce)
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
