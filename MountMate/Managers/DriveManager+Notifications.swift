//  Created by homielab.com

import AppKit
import Foundation

extension DriveManager {
  // MARK: - Notification Handling

  func setupDiskChangeObservers() {
    let notificationCenter = NSWorkspace.shared.notificationCenter
    notificationCenter.addObserver(
      self, selector: #selector(handleDiskNotification),
      name: NSWorkspace.didMountNotification,
      object: nil)
    notificationCenter.addObserver(
      self, selector: #selector(handleDiskNotification),
      name: NSWorkspace.didUnmountNotification,
      object: nil)
    // Disks that appear or vanish without ever mounting (blocked, not
    // formatted) post no workspace notification.
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDiskNotification),
      name: .diskAppearanceDidChange, object: nil)
    // The list can be stale after sleep (disks removed or changed meanwhile).
    notificationCenter.addObserver(
      self, selector: #selector(handleDiskNotification),
      name: NSWorkspace.didWakeNotification,
      object: nil)
  }

  @objc func handleDiskNotification(notification: NSNotification) {
    // Share mounts are tracked by NetworkMountManager; skip the disk refresh.
    if notification.name == NSWorkspace.didMountNotification
      || notification.name == NSWorkspace.didUnmountNotification
    {
      let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
      let entries = MountTable.entries()
      let isLocal = DiskEventFilter.isLocalDiskEvent(
        volumeURL: volumeURL, entries: entries,
        knownNetworkMountPoints: knownNetworkMountPoints)
      if let entries { knownNetworkMountPoints = DiskEventFilter.networkMountPoints(in: entries) }
      guard isLocal else {
        Log.drive.debug("Network share mount event ignored for the disk list.")
        return
      }
    }
    refreshDebounceTimer?.invalidate()
    let qos = Self.coalescedRefreshQoS(
      pendingNotificationRefreshQoS, Self.refreshQoS(for: notification.name))
    pendingNotificationRefreshQoS = qos
    // Short debounce: coalesces bursts (a disk with several volumes posts one
    // notification per volume) without making plug-ins feel slow.
    refreshDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
      [weak self] _ in
      if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
        Log.drive.info(
          "Disk notification received for volume \(volumeURL.lastPathComponent, privacy: .private). Refreshing list."
        )
      } else {
        Log.drive.info("Disk notification received. Refreshing list.")
      }
      self?.pendingNotificationRefreshQoS = nil
      self?.refreshDrives(qos: qos)
    }
  }

  /// QoS of the list refresh a notification triggers. A plugged-in disk, a
  /// disk that appeared or vanished and waking up are moments the user waits
  /// for the list, so they must not be throttled like background work; an
  /// unmount only removes a row and can run at `.utility`.
  static func refreshQoS(for name: Notification.Name) -> DispatchQoS.QoSClass {
    switch name {
    case NSWorkspace.didMountNotification, .diskAppearanceDidChange,
      NSWorkspace.didWakeNotification:
      return .userInitiated
    default:
      return .utility
    }
  }

  /// QoS for notifications coalesced into one refresh: the highest one wins.
  static func coalescedRefreshQoS(
    _ pending: DispatchQoS.QoSClass?, _ next: DispatchQoS.QoSClass
  ) -> DispatchQoS.QoSClass {
    guard let pending else { return next }
    return rank(of: pending) >= rank(of: next) ? pending : next
  }

  /// QoS of the retry after a failed refresh: the failed refresh's own QoS,
  /// so a plug-in or wake refresh is not retried as throttled `.utility`
  /// work. A follow-up that was waiting runs at `.userInitiated`, and the
  /// retry serves it, so it is raised to that.
  static func retryRefreshQoS(
    after failed: DispatchQoS.QoSClass, servingFollowup: Bool
  ) -> DispatchQoS.QoSClass {
    servingFollowup ? coalescedRefreshQoS(failed, .userInitiated) : failed
  }

  private static func rank(of qos: DispatchQoS.QoSClass) -> Int {
    switch qos {
    case .userInteractive: return 5
    case .userInitiated: return 4
    case .default: return 3
    case .utility: return 2
    case .background: return 1
    default: return 0
    }
  }
}
