//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeMenuRulesTests: XCTestCase {
  private func volume(
    mounted: Bool, mountPoint: String? = "/Volumes/Data", isProtected: Bool = false
  )
    -> Volume
  {
    Volume(
      id: "v1", deviceIdentifier: "disk2s1", diskUUID: nil, name: "Data",
      isMounted: mounted, mountPoint: mountPoint, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
      isProtected: isProtected, snapshots: [], storageError: nil)
  }

  private func rules(
    _ volume: Volume, _ configure: (inout VolumeRowState) -> Void = { _ in }
  ) -> VolumeMenuRules {
    var state = VolumeRowState()
    configure(&state)
    return VolumeMenuRules(volume: volume, state: state)
  }

  func testMountedVolumeShowsMountedActionsOnly() {
    let r = rules(volume(mounted: true))
    XCTAssertTrue(r.showsMountedActions)
    XCTAssertTrue(r.showsPathActions)
    XCTAssertFalse(r.showsMountActions)
    XCTAssertEqual(r.protectAction, .protect)
  }

  func testUnmountedVolumeShowsMountActionsOnly() {
    let r = rules(volume(mounted: false, isProtected: true))
    XCTAssertTrue(r.showsMountActions)
    XCTAssertFalse(r.showsMountedActions)
    XCTAssertFalse(r.showsPathActions)
    XCTAssertNil(r.protectAction)
  }

  func testProtectedMountedVolumeOffersUnprotect() {
    XCTAssertEqual(rules(volume(mounted: true, isProtected: true)).protectAction, .unprotect)
  }

  func testPathActionsNeedAMountPoint() {
    XCTAssertFalse(rules(volume(mounted: true, mountPoint: nil)).showsPathActions)
  }

  func testReconnectNowOnlyWhileUnmountedAndReconnecting() {
    XCTAssertTrue(rules(volume(mounted: false)) { $0.isReconnecting = true }.showsReconnectNow)
    XCTAssertFalse(rules(volume(mounted: true)) { $0.isReconnecting = true }.showsReconnectNow)
    XCTAssertFalse(rules(volume(mounted: false)).showsReconnectNow)
  }

  func testPinAndKeepAliveReflectRowState() {
    let r = rules(volume(mounted: true)) {
      $0.isPinned = true
      $0.isKeepAlive = true
    }
    XCTAssertTrue(r.isPinned)
    XCTAssertTrue(r.isKeepAlive)
    XCTAssertFalse(rules(volume(mounted: true)).isPinned)
  }

  func testIdleUnmountSubmenuAndItsDisabledState() {
    XCTAssertFalse(rules(volume(mounted: true)).showsIdleUnmount)
    let r = rules(volume(mounted: true)) {
      $0.canUnmountWhenIdle = true
      $0.idleUnmountMinutes = 15
    }
    XCTAssertTrue(r.showsIdleUnmount)
    XCTAssertFalse(r.idleUnmountDisabled)
    XCTAssertTrue(r.isCurrentIdleChoice(15))
    XCTAssertFalse(r.isCurrentIdleChoice(0))
    XCTAssertTrue(
      rules(volume(mounted: true)) {
        $0.canUnmountWhenIdle = true
        $0.isKeepAlive = true
      }.idleUnmountDisabled)
  }

  func testForgetSavedPasswordOnlyWithSavedPassword() {
    XCTAssertFalse(rules(volume(mounted: false)).showsForgetSavedPassword)
    XCTAssertTrue(
      rules(volume(mounted: false)) { $0.hasSavedPassword = true }.showsForgetSavedPassword)
  }

  func testIdleUnmountChoiceTitleUsesOffForZero() {
    XCTAssertEqual(
      VolumeMenuRules.idleUnmountChoiceTitle(0),
      NSLocalizedString("Off", comment: "Unmount When Idle: disabled"))
    XCTAssertTrue(VolumeMenuRules.idleUnmountChoiceTitle(10).contains("10"))
  }
}
