//  Created by homielab.com

import AppKit
import Foundation

/// What started a mount. Only mounts the user asked for may open Finder.
enum MountTrigger: Sendable, CaseIterable {
  /// Mount or Mount Read-Only in the popover (row button or right-click menu).
  case popover
  /// Mount All or Mount All Network Shares (keyboard shortcut).
  case mountAll
  /// A Shortcuts action.
  case shortcuts
  /// Keep Alive reconnecting a volume or share.
  case keepAlive
  /// Mount Again on Wake.
  case wake
  /// Anything else that mounts on its own: a disk mounted as it is plugged
  /// in or at login, a remount after a mount point change.
  case automatic

  var isUserRequested: Bool {
    switch self {
    case .popover, .mountAll, .shortcuts: true
    case .keepAlive, .wake, .automatic: false
    }
  }
}

/// "Open in Finder after mounting": decides whether a finished mount opens a
/// Finder window at its mount point. Pure apart from `open`, which takes the
/// opener as a parameter so tests never open Finder.
enum OpenAfterMountRules {
  static let enabledKey = "openFinderAfterMount"

  /// Off unless the user turned it on.
  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: enabledKey)
  }

  /// Opens only a successful mount the user asked for, never a blocked
  /// volume, and only when the mount point is known.
  static func shouldOpen(
    trigger: MountTrigger, isEnabled: Bool, succeeded: Bool, isBlocked: Bool,
    mountPoint: String?
  ) -> Bool {
    guard isEnabled, succeeded, trigger.isUserRequested, !isBlocked else { return false }
    guard let mountPoint, !mountPoint.isEmpty else { return false }
    return true
  }

  /// Mount points to open after mounting the volumes `requestedIDs`: each
  /// one that is now mounted and not blocked, once, in the requested order.
  /// `volumes` is the refreshed list, so a failed mount has no mount point.
  static func mountPoints(
    afterMounting requestedIDs: [String], in volumes: [Volume], trigger: MountTrigger,
    isEnabled: Bool, isBlocked: (Volume) -> Bool
  ) -> [String] {
    var seen = Set<String>()
    return requestedIDs.compactMap { id -> String? in
      guard let volume = volumes.first(where: { $0.id == id }) else { return nil }
      let mountPoint = volume.isMounted ? volume.mountPoint : nil
      guard
        shouldOpen(
          trigger: trigger, isEnabled: isEnabled, succeeded: volume.isMounted,
          isBlocked: isBlocked(volume), mountPoint: mountPoint),
        let mountPoint, seen.insert(mountPoint).inserted
      else { return nil }
      return mountPoint
    }
  }

  /// Opens each path in a Finder window showing its contents.
  static func open(
    _ mountPoints: [String],
    opener: (URL) -> Void = { NSWorkspace.shared.open($0) }
  ) {
    for path in mountPoints {
      opener(URL(fileURLWithPath: path, isDirectory: true))
    }
  }
}
