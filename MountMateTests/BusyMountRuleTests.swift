import XCTest

@testable import MountMate

final class BusyMountRuleTests: XCTestCase {
  func testIdleVolumeIsNotRejected() {
    XCTAssertFalse(DriveManager.shouldRejectAsBusy(volumeID: "a", busyIDs: [], ownsBusy: false))
    XCTAssertFalse(DriveManager.shouldRejectAsBusy(volumeID: "a", busyIDs: ["b"], ownsBusy: false))
  }

  func testBusyFromAnotherOperationIsRejected() {
    XCTAssertTrue(DriveManager.shouldRejectAsBusy(volumeID: "a", busyIDs: ["a"], ownsBusy: false))
  }

  func testOwnBusyIsNotRejected() {
    XCTAssertFalse(DriveManager.shouldRejectAsBusy(volumeID: "a", busyIDs: ["a"], ownsBusy: true))
  }

  // Remount and Force Unmount do not own the flag when they start, so a
  // mount or unmount already running on the volume blocks them.
  func testRemountOrForceUnmountOfBusyVolumeIsRejected() {
    XCTAssertTrue(
      DriveManager.shouldRejectAsBusy(volumeID: "disk4s1", busyIDs: ["disk4s1"], ownsBusy: false))
  }

  func testRemountOrForceUnmountOfIdleVolumeRuns() {
    XCTAssertFalse(
      DriveManager.shouldRejectAsBusy(volumeID: "disk4s1", busyIDs: ["disk5s1"], ownsBusy: false))
  }
}
