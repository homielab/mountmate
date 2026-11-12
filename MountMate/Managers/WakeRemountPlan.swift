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

  /// A saved network share, by its saved identity (never its mount path).
  struct ShareEntry: Codable, Equatable, Sendable {
    let shareID: UUID
    let name: String
  }

  private(set) var entries: [Entry]
  /// Network shares unmounted with the disks ("Also unmount network shares").
  private(set) var shares: [ShareEntry] = []
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

  /// A plan for network shares only.
  init(shares: [NetworkShare], volumes: [Volume] = []) {
    self.init(volumes: volumes)
    var seen = Set<UUID>()
    self.shares = shares.compactMap { share in
      seen.insert(share.id).inserted ? ShareEntry(shareID: share.id, name: share.name) : nil
    }
  }

  // Plans saved before shares were recorded have no `shares` key.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    entries = try container.decode([Entry].self, forKey: .entries)
    shares = try container.decodeIfPresent([ShareEntry].self, forKey: .shares) ?? []
    sleepTimedOut = try container.decodeIfPresent(Bool.self, forKey: .sleepTimedOut) ?? false
  }

  var isEmpty: Bool { entries.isEmpty && shares.isEmpty }

  /// This plan with `other`'s volumes added (each volume once). A sleep
  /// time-out mark from either plan is kept.
  func adding(_ other: WakeRemountPlan) -> WakeRemountPlan {
    var copy = self
    let known = Set(entries.map(\.volumeUUID))
    copy.entries += other.entries.filter { !known.contains($0.volumeUUID) }
    let knownShares = Set(shares.map(\.shareID))
    copy.shares += other.shares.filter { !knownShares.contains($0.shareID) }
    copy.sleepTimedOut = sleepTimedOut || other.sleepTimedOut
    return copy
  }

  /// The plan without `volumes` (unmounts that failed, or that the user did
  /// themselves).
  func excluding(_ volumes: [Volume]) -> WakeRemountPlan {
    var copy = self
    let uuids = Set(volumes.compactMap(\.stableVolumeUUID))
    copy.entries.removeAll { uuids.contains($0.volumeUUID) }
    return copy
  }

  /// The plan without the shares `ids` (unmounts that failed, or that the
  /// user did themselves).
  func excludingShares(_ ids: Set<UUID>) -> WakeRemountPlan {
    var copy = self
    copy.shares.removeAll { ids.contains($0.shareID) }
    return copy
  }

  /// The shares still to mount: not mounted yet (`mountedIDs`).
  func remainingShares(afterMounted mountedIDs: Set<UUID>) -> WakeRemountPlan {
    excludingShares(mountedIDs)
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
