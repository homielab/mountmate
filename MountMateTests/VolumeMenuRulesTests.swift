//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeMenuRulesTests: XCTestCase {
  private func volume(
    mounted: Bool, mountPoint: String? = "/Volumes/Data", isProtected: Bool = false,
    category: DriveCategory = .user, readOnly: Bool = false
  )
    -> Volume
  {
    var volume = Volume(
      id: "v1", deviceIdentifier: "disk2s1", diskUUID: nil, name: "Data",
      isMounted: mounted, mountPoint: mountPoint, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: category,
      isProtected: isProtected, snapshots: [], storageError: nil)
    volume.isReadOnly = readOnly
    return volume
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
    let protected = rules(volume(mounted: true, isProtected: true)) {
      $0.canUnmountWhenIdle = true
      $0.idleUnmountMinutes = 15
    }
    XCTAssertTrue(protected.showsIdleUnmount)
    XCTAssertTrue(protected.idleUnmountDisabled)
    XCTAssertTrue(protected.isCurrentIdleChoice(15))
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

  func testVerifyVolumeShowsOnlyForMountedExternalUserVolumes() {
    let externalMounted = rules(volume(mounted: true)) {
      $0.isExternalDisk = true
    }
    XCTAssertTrue(externalMounted.showsVerifyVolume)

    let externalUnmounted = rules(volume(mounted: false)) {
      $0.isExternalDisk = true
    }
    XCTAssertFalse(externalUnmounted.showsVerifyVolume)

    let internalMounted = rules(volume(mounted: true)) {
      $0.isExternalDisk = false
    }
    XCTAssertFalse(internalMounted.showsVerifyVolume)

    let externalSystemMounted = rules(volume(mounted: true, category: .system)) {
      $0.isExternalDisk = true
    }
    XCTAssertFalse(externalSystemMounted.showsVerifyVolume)
  }

  func testVerifyVolumeReflectsVerifyingState() {
    let verifying = rules(volume(mounted: true)) {
      $0.isExternalDisk = true
      $0.isVerifying = true
    }
    XCTAssertTrue(verifying.showsVerifyVolume)
    XCTAssertTrue(verifying.isVerifying)

    let notVerifying = rules(volume(mounted: true)) {
      $0.isExternalDisk = true
      $0.isVerifying = false
    }
    XCTAssertTrue(notVerifying.showsVerifyVolume)
    XCTAssertFalse(notVerifying.isVerifying)
  }

  func testRenameShowsOnlyForWritableUnprotectedMountedExternalUserVolumes() {
    XCTAssertTrue(rules(volume(mounted: true)) { $0.isExternalDisk = true }.showsRename)
    XCTAssertFalse(rules(volume(mounted: false)) { $0.isExternalDisk = true }.showsRename)
    XCTAssertFalse(rules(volume(mounted: true)).showsRename)
    XCTAssertFalse(
      rules(volume(mounted: true, readOnly: true)) { $0.isExternalDisk = true }.showsRename)
    XCTAssertFalse(
      rules(volume(mounted: true, isProtected: true)) { $0.isExternalDisk = true }.showsRename)
    XCTAssertFalse(
      rules(volume(mounted: true, category: .system)) { $0.isExternalDisk = true }.showsRename)
  }

  func testBusyVolumeDisablesMountUnmountVerifyAndRename() {
    let idle = rules(volume(mounted: true))
    XCTAssertFalse(idle.disablesVolumeOperations)
    let busyMounted = rules(volume(mounted: true)) { $0.isBusy = true }
    XCTAssertTrue(busyMounted.disablesVolumeOperations)
    XCTAssertTrue(busyMounted.isBusy)
    let busyUnmounted = rules(volume(mounted: false)) { $0.isBusy = true }
    XCTAssertTrue(busyUnmounted.disablesVolumeOperations)
    XCTAssertTrue(busyUnmounted.showsMountActions)
  }

  // MARK: - Custom mount point

  private func volume(contentType: String?, mountedType: String?) -> Volume {
    var volume = Volume(
      id: "v1", deviceIdentifier: "disk2s1", diskUUID: nil, name: "Data",
      isMounted: mountedType != nil, mountPoint: "/Volumes/Data", freeSpace: nil,
      totalSize: nil, usedSpace: nil, usedBytes: nil, fileSystemType: contentType,
      usagePercentage: nil, category: .user, isProtected: false, snapshots: [],
      storageError: nil)
    volume.mountedFileSystemType = mountedType
    return volume
  }

  func testCustomMountPointIsOffForKnownNTFSVolumes() {
    for (content, mounted) in [
      ("Windows_NTFS", nil), ("Microsoft Basic Data", "ufsd_NTFS"),
      ("Microsoft Basic Data", "ntfs"),
    ] as [(String, String?)] {
      let reason = rules(volume(contentType: content, mountedType: mounted))
        .customMountPointDisabledReason
      XCTAssertTrue(reason?.contains("NTFS") ?? false, "\(content) \(mounted ?? "-")")
    }
  }

  func testCustomMountPointStaysOnForBuiltInOrUnknownFileSystems() {
    XCTAssertNil(
      rules(volume(contentType: "Apple_APFS", mountedType: "apfs")).customMountPointDisabledReason)
    XCTAssertNil(
      rules(volume(contentType: "Microsoft Basic Data", mountedType: "exfat"))
        .customMountPointDisabledReason)
    XCTAssertNil(
      rules(volume(contentType: "Microsoft Basic Data", mountedType: nil))
        .customMountPointDisabledReason)
  }
}
