//  Created by homielab.com

import Foundation

/// The volumes "Unmount All Disks on Sleep" took away, so they can be mounted
/// again when the Mac wakes. A pure value: `WakeRemountManager` saves it and
/// acts on it.
struct WakeRemountPlan: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    let volumeUUID: String
    let name: String
  }

  private(set) var entries: [Entry]
  /// The unmount before sleep hit its time limit, so some volumes may still
  /// have been mounted when the Mac slept.
  private(set) var sleepTimedOut = false

  /// Volumes without a stable UUID are left out: their device identifier can
  /// belong to another disk after wake.
  init(volumes: [Volume]) {
    var seen = Set<String>()
    entries = volumes.compactMap { volume in
      guard let uuid = volume.stableVolumeUUID, seen.insert(uuid).inserted else { return nil }
      return Entry(volumeUUID: uuid, name: volume.name)
    }
  }

  var isEmpty: Bool { entries.isEmpty }

  /// The plan without `volumes` (unmounts that failed, or that the user did
  /// themselves).
  func excluding(_ volumes: [Volume]) -> WakeRemountPlan {
    var copy = self
    let uuids = Set(volumes.compactMap(\.stableVolumeUUID))
    copy.entries.removeAll { uuids.contains($0.volumeUUID) }
    return copy
  }

  func markingSleepTimedOut() -> WakeRemountPlan {
    var copy = self
    copy.sleepTimedOut = true
    return copy
  }

  /// The entries still to mount: not mounted yet (`mountedUUIDs`).
  func remaining(afterMounted mountedUUIDs: Set<String>) -> WakeRemountPlan {
    var copy = self
    copy.entries.removeAll { mountedUUIDs.contains($0.volumeUUID) }
    return copy
  }

  /// The entries that can be mounted now: connected (`presentUUIDs`) and not
  /// mounted. Disks that are not plugged in are skipped.
  func volumesToMount(presentUUIDs: Set<String>, mountedUUIDs: Set<String>) -> [Entry] {
    entries.filter {
      presentUUIDs.contains($0.volumeUUID) && !mountedUUIDs.contains($0.volumeUUID)
    }
  }

  /// Names of volumes that were not unmounted before sleep (the time limit
  /// ran out) and are still mounted.
  func unfinishedNames(stillMounted mountedUUIDs: Set<String>) -> [String] {
    guard sleepTimedOut else { return [] }
    return entries.filter { mountedUUIDs.contains($0.volumeUUID) }.map(\.name)
  }
}
