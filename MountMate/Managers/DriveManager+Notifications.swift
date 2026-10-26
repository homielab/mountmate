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
      self?.refreshDrives()
    }
  }
}
