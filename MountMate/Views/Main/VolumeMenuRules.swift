//  Created by homielab.com

import Foundation

/// Which items a volume's context menu shows, and which variant of each.
/// Pure, so the conditions can be tested without building the menu.
struct VolumeMenuRules: Equatable {
  enum ProtectAction: Equatable {
    case protect
    case unprotect
  }

  let isMounted: Bool
  let isProtected: Bool
  let hasMountPoint: Bool
  let isReconnecting: Bool
  let isPinned: Bool
  let isKeepAlive: Bool
  let canUnmountWhenIdle: Bool
  let hasSavedPassword: Bool
  let idleUnmountMinutes: Int

  init(volume: Volume, state: VolumeRowState) {
    isMounted = volume.isMounted
    isProtected = volume.isProtected
    hasMountPoint = volume.mountPoint != nil
    isReconnecting = state.isReconnecting
    isPinned = state.isPinned
    isKeepAlive = state.isKeepAlive
    canUnmountWhenIdle = state.canUnmountWhenIdle
    hasSavedPassword = state.hasSavedPassword
    idleUnmountMinutes = state.idleUnmountMinutes
  }

  /// "Reconnect Now": Keep Alive is waiting to bring this volume back.
  var showsReconnectNow: Bool { isReconnecting && !isMounted }

  /// Unmount, Open in Finder and the Protect item: only while mounted.
  var showsMountedActions: Bool { isMounted }

  /// "Copy Path" and "Open in Terminal" need a mounted volume with a path.
  var showsPathActions: Bool { isMounted && hasMountPoint }

  /// Protect / Unprotect from "Unmount All": only while mounted.
  var protectAction: ProtectAction? {
    guard isMounted else { return nil }
    return isProtected ? .unprotect : .protect
  }

  /// "Mount" and "Mount Read-Only": only while unmounted.
  var showsMountActions: Bool { !isMounted }

  /// "Unmount When Idle" submenu: external physical disks only.
  var showsIdleUnmount: Bool { canUnmountWhenIdle }

  /// Idle unmount is off while the volume is kept mounted.
  var idleUnmountDisabled: Bool { isKeepAlive }

  func isCurrentIdleChoice(_ minutes: Int) -> Bool { minutes == idleUnmountMinutes }

  var showsForgetSavedPassword: Bool { hasSavedPassword }

  static func idleUnmountChoiceTitle(_ minutes: Int) -> String {
    guard minutes > 0 else {
      return NSLocalizedString("Off", comment: "Unmount When Idle: disabled")
    }
    return String(
      format: NSLocalizedString(
        "After %d min Without Use", comment: "Unmount When Idle choice; minutes"), minutes)
  }
}
