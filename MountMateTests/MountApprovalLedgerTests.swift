//  Created by homielab.com

import XCTest

@testable import MountMate

final class MountApprovalLedgerTests: XCTestCase {
  private var current = Date(timeIntervalSince1970: 1_000_000)

  private func makeLedger() -> MountApprovalLedger {
    MountApprovalLedger(now: { [unowned self] in self.current })
  }

  func testApprovalIsUsedOnce() {
    var ledger = makeLedger()
    ledger.approve("disk4s1")
    XCTAssertTrue(ledger.consumeApproval(bsdName: "disk4s1", volumeUUID: nil, diskUUID: nil))
    XCTAssertFalse(ledger.consumeApproval(bsdName: "disk4s1", volumeUUID: nil, diskUUID: nil))
  }

  func testApprovalExpiresAfter60Seconds() {
    var ledger = makeLedger()
    ledger.approve("disk4s1")
    current = current.addingTimeInterval(59)
    XCTAssertTrue(ledger.consumeApproval(bsdName: "disk4s1", volumeUUID: nil, diskUUID: nil))

    ledger.approve("disk4s1")
    current = current.addingTimeInterval(60)
    XCTAssertFalse(ledger.consumeApproval(bsdName: "disk4s1", volumeUUID: nil, diskUUID: nil))
  }

  func testApprovalMatchesBSDName() {
    var ledger = makeLedger()
    ledger.approve("disk4s1")
    XCTAssertFalse(ledger.consumeApproval(bsdName: "disk5s1", volumeUUID: "x", diskUUID: "y"))
    XCTAssertTrue(ledger.consumeApproval(bsdName: "disk4s1", volumeUUID: "x", diskUUID: "y"))
  }

  func testApprovalMatchesVolumeUUIDIgnoringCase() {
    var ledger = makeLedger()
    ledger.approve("ABCD-1234")
    XCTAssertTrue(
      ledger.consumeApproval(bsdName: "disk9s1", volumeUUID: "abcd-1234", diskUUID: nil))
  }

  func testApprovalMatchesDiskUUID() {
    var ledger = makeLedger()
    ledger.approve("disk-uuid")
    XCTAssertTrue(
      ledger.consumeApproval(bsdName: "disk9s1", volumeUUID: "vol", diskUUID: "DISK-UUID"))
  }

  func testNoIdentifiersNeverMatch() {
    var ledger = makeLedger()
    ledger.approve("disk4s1")
    XCTAssertFalse(ledger.consumeApproval(bsdName: nil, volumeUUID: nil, diskUUID: nil))
  }

  func testWithdrawnApprovalIsGone() {
    var ledger = makeLedger()
    ledger.approve("disk4s1")
    ledger.withdrawApproval(for: "DISK4S1")
    XCTAssertFalse(ledger.consumeApproval(bsdName: "disk4s1", volumeUUID: nil, diskUUID: nil))
  }

  func testStaleExpiryDoesNotWithdrawNewerApproval() {
    var ledger = makeLedger()
    let first = ledger.approve("disk4s1")
    current = current.addingTimeInterval(10)
    ledger.approve("disk4s1")
    ledger.withdrawApproval(for: "disk4s1", ifExpiring: first)
    XCTAssertTrue(ledger.consumeApproval(bsdName: "disk4s1", volumeUUID: nil, diskUUID: nil))
  }

  func testUnknownDiskCountsAsAutomaticMountAndIsRecorded() {
    var ledger = makeLedger()
    XCTAssertTrue(ledger.isAutomaticMount(bsdName: "disk4s1"))
    current = current.addingTimeInterval(20)
    // The first call recorded the disk, so 20 s later it is a requested mount.
    XCTAssertFalse(ledger.isAutomaticMount(bsdName: "disk4s1"))
  }

  func testMountWithinWindowAfterAppearanceIsAutomatic() {
    var ledger = makeLedger()
    ledger.recordAppearance(of: "disk4s1")
    current = current.addingTimeInterval(14)
    XCTAssertTrue(ledger.isAutomaticMount(bsdName: "disk4s1"))
    current = current.addingTimeInterval(1)
    XCTAssertFalse(ledger.isAutomaticMount(bsdName: "disk4s1"))
  }

  func testForgottenDiskIsAutomaticAgain() {
    var ledger = makeLedger()
    ledger.recordAppearance(of: "disk4s1")
    current = current.addingTimeInterval(100)
    ledger.forgetAppearance(of: "disk4s1")
    XCTAssertTrue(ledger.isAutomaticMount(bsdName: "DISK4S1"))
  }

  func testMissingBSDNameIsAutomatic() {
    var ledger = makeLedger()
    XCTAssertTrue(ledger.isAutomaticMount(bsdName: nil))
  }

  func testRemoveAllClearsApprovalsAndAppearances() {
    var ledger = makeLedger()
    ledger.approve("disk4s1")
    ledger.recordAppearance(of: "disk5s1")
    current = current.addingTimeInterval(100)
    ledger.removeAll()
    XCTAssertFalse(ledger.consumeApproval(bsdName: "disk4s1", volumeUUID: nil, diskUUID: nil))
    XCTAssertTrue(ledger.isAutomaticMount(bsdName: "disk5s1"))
  }
}
