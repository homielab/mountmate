//  Created by homielab.com

import Foundation

/// Spots external volumes that disappear while still mounted: a USB drive or
/// SD card pulled out (or a cable that came loose) without ejecting, which
/// can leave a copy half written. Pure: `NotificationManager` feeds it the
/// list after each refresh and the unmount, sleep and wake events.
///
/// Only volumes of external physical disks are watched: disk images,
/// internal disks, system volumes and Time Machine volumes never are. A
/// volume does not count as pulled out when
/// - it was unmounted first and is still listed (Unmount, idle unmount),
/// - an unmount of its mount point was requested shortly before (Finder,
///   `diskutil`, MountMate's own Eject, Time Machine), which also covers an
///   eject that finishes inside the list's refresh debounce,
/// - MountMate is ejecting its disk or unmounting it right now,
/// - the Mac is asleep or has just woken up (disks re-enumerate then),
/// - its mount point is still mounted (hidden from the list, or not torn
///   down yet); it is checked again on the next refresh.
///
/// Not thread-safe: main queue only.
struct UnexpectedRemovalTracker: Sendable {
  static let enabledKey = "unexpectedRemovalWarningEnabled"
  /// How long a requested unmount of a mount point explains its volume
  /// disappearing.
  static let requestedUnmountMemory: TimeInterval = 10
  /// How long after wake vanished volumes are not reported.
  static let wakeQuietPeriod: TimeInterval = 30

  /// A volume that disappeared while mounted.
  struct Removal: Equatable, Sendable {
    let volumeID: String
    let name: String
    let mountPoint: String
  }

  private struct Watched: Equatable, Sendable {
    let volumeID: String
    let name: String
    let mountPoint: String
    let diskID: String
  }

  /// Mounted, watched volumes of the last refresh, by volume ID.
  private var watched: [String: Watched] = [:]
  /// When an unmount of each mount point (normalized) was last requested.
  private var requestedUnmounts: [String: Date] = [:]
  private var isAsleep = false
  private var quietUntil: Date?

  init() {}

  /// The user's setting; off by default.
  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: enabledKey)
  }

  /// Whether a pulled-out `volume` of `disk` would be reported.
  static func isWatched(
    _ volume: Volume, on disk: PhysicalDisk, unverifiedDiskIDs: Set<String> = []
  ) -> Bool {
    disk.type == .physical && !unverifiedDiskIDs.contains(disk.id) && volume.isMounted
      && volume.mountPoint != nil && volume.category == .user && !volume.isTimeMachine
  }

  /// "/Volumes/Backup/" and "/Volumes/Backup" are the same mount point.
  static func normalized(_ mountPoint: String) -> String {
    var path = mountPoint
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  // MARK: - Events

  /// An unmount of `mountPoint` was requested (`willUnmountNotification`).
  mutating func recordRequestedUnmount(mountPoint: String, at now: Date) {
    requestedUnmounts[Self.normalized(mountPoint)] = now
  }

  mutating func systemWillSleep() {
    isAsleep = true
  }

  mutating func systemDidWake(at now: Date) {
    isAsleep = false
    quietUntil = now.addingTimeInterval(Self.wakeQuietPeriod)
  }

  /// Forgets the watched volumes and requested unmounts (the setting or
  /// notifications were turned off); the next refresh starts afresh.
  mutating func reset() {
    watched.removeAll()
    requestedUnmounts.removeAll()
  }

  // MARK: - Refresh

  /// Compares a refreshed list with the previous one and returns the
  /// volumes that were pulled out since, sorted by name. Each is reported
  /// once.
  /// - Parameters:
  ///   - mountedPaths: the mount points in the kernel mount table, or nil
  ///     when it could not be read (then nothing is reported this time).
  mutating func removals(
    in disks: [PhysicalDisk], unverifiedDiskIDs: Set<String> = [],
    ejectingDiskIDs: Set<String> = [], busyVolumeIDs: Set<String> = [],
    mountedPaths: Set<String>?, now: Date
  ) -> [Removal] {
    requestedUnmounts = requestedUnmounts.filter {
      now.timeIntervalSince($0.value) <= Self.requestedUnmountMemory
    }
    let isQuiet = isAsleep || quietUntil.map { now < $0 } == true
    let mounted = mountedPaths.map { Set($0.map(Self.normalized)) }

    var next: [String: Watched] = [:]
    var listedVolumeIDs = Set<String>()
    for disk in disks {
      for volume in disk.allVolumes {
        listedVolumeIDs.insert(volume.id)
        guard Self.isWatched(volume, on: disk, unverifiedDiskIDs: unverifiedDiskIDs),
          let mountPoint = volume.mountPoint
        else { continue }
        next[volume.id] = Watched(
          volumeID: volume.id, name: volume.name, mountPoint: Self.normalized(mountPoint),
          diskID: disk.id)
      }
    }

    var removed: [Removal] = []
    for (id, old) in watched where next[id] == nil && !listedVolumeIDs.contains(id) {
      let wasExpected =
        isQuiet || ejectingDiskIDs.contains(old.diskID) || busyVolumeIDs.contains(id)
        || requestedUnmounts[old.mountPoint] != nil
      if wasExpected { continue }
      guard let mounted, !mounted.contains(old.mountPoint) else {
        // Still mounted (or unknown): keep watching it.
        next[id] = old
        continue
      }
      removed.append(Removal(volumeID: id, name: old.name, mountPoint: old.mountPoint))
    }
    watched = next
    return removed.sorted { $0.name < $1.name }
  }
}
