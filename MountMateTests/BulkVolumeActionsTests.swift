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
    XCTAssertEqual(BulkVolumeActions.runConcurrently([]) { _ in false }, [])
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
}
