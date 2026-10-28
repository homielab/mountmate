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
}
