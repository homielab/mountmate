import XCTest

@testable import MountMate

final class SMARTAlertTrackerTests: XCTestCase {
  private func disk(_ id: String, smart: SMARTStatus) -> PhysicalDisk {
    PhysicalDisk(
      id: id, diskUUID: nil, connectionType: "USB", name: "Disk \(id)", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: .physical, isRAIDSet: false,
      partitions: [], containers: [], storageError: nil, smartStatus: smart)
  }

  func testFailingDiskIsReportedOnceAndNotAgainOnLaterRefreshes() {
    var tracker = SMARTAlertTracker()
    let disks = [disk("disk4", smart: .failing), disk("disk5", smart: .verified)]
    XCTAssertEqual(tracker.newlyFailing(in: disks).map(\.id), ["disk4"])
    XCTAssertTrue(tracker.newlyFailing(in: disks).isEmpty)
    XCTAssertTrue(tracker.newlyFailing(in: disks).isEmpty)
  }

  func testReusedIdentifierAfterTheDiskWasUnpluggedIsReportedAgain() {
    var tracker = SMARTAlertTracker()
    XCTAssertEqual(tracker.newlyFailing(in: [disk("disk4", smart: .failing)]).count, 1)
    XCTAssertTrue(tracker.newlyFailing(in: []).isEmpty)
    XCTAssertEqual(tracker.newlyFailing(in: [disk("disk4", smart: .failing)]).count, 1)
  }

  func testDiskThatRecoversAndFailsAgainIsReportedAgain() {
    var tracker = SMARTAlertTracker()
    XCTAssertEqual(tracker.newlyFailing(in: [disk("disk4", smart: .failing)]).count, 1)
    XCTAssertTrue(tracker.newlyFailing(in: [disk("disk4", smart: .verified)]).isEmpty)
    XCTAssertEqual(tracker.newlyFailing(in: [disk("disk4", smart: .failing)]).count, 1)
  }
}
