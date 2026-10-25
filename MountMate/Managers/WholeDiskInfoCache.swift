//  Created by homielab.com

import Foundation

/// `diskutil info` of each whole disk, remembered between refreshes.
///
/// What MountMate reads from it (internal or external, bus, RAID role, disk
/// image, name, UUID) does not change while the disk stays attached, so a
/// disk whose `diskutil list` identity is unchanged reuses its entry for
/// `ttl` seconds instead of starting one `diskutil` process per disk on
/// every refresh. New or changed disks, and entries older than `ttl`, are
/// fetched again, concurrently and without blocking the calling thread.
///
/// When a fetch fails or times out (busy or spinning-up disk), the last good
/// info of the same disk is used regardless of its age, so a disk is never
/// re-classified (e.g. an internal disk shown as removable) just because its
/// info was briefly unavailable.
final class WholeDiskInfoCache {
  /// A whole disk as listed by `diskutil list`.
  struct Disk: Equatable {
    let identifier: String
    /// Size, content and partition layout (see `listIdentity(of:)`); a
    /// change means the BSD name now belongs to a different disk.
    let identity: String
  }

  struct Lookup {
    /// Info per BSD name, fresh or cached.
    var info: [String: [String: Any]] = [:]
    /// Disks with no info at all (fetch failed, nothing cached).
    var unclassified: Set<String> = []
    /// Disks for which `diskutil info` ran in this lookup.
    var fetched: Set<String> = []
    /// Disks whose cached info was used without running `diskutil info`.
    var reused: Set<String> = []
  }

  /// Runs `diskutil info` for one BSD name; nil when it failed or timed out.
  typealias Fetcher = (String) -> [String: Any]?

  static let defaultTTL: TimeInterval = 30

  let ttl: TimeInterval
  private let fetch: Fetcher
  private let now: () -> Date
  private let queue: DispatchQueue

  private struct Entry {
    let info: [String: Any]
    let identity: String
    let fetchedAt: Date
  }
  private var entries: [String: Entry] = [:]
  private let lock = NSLock()

  init(
    ttl: TimeInterval = WholeDiskInfoCache.defaultTTL,
    queue: DispatchQueue = .global(qos: .userInitiated),
    now: @escaping () -> Date = Date.init,
    fetch: @escaping Fetcher
  ) {
    self.ttl = ttl
    self.queue = queue
    self.now = now
    self.fetch = fetch
  }

  /// Size, content type and partition layout of a whole disk as reported by
  /// `diskutil list`. Cheap to compute and stable across refreshes; renaming
  /// or mounting a volume does not change it.
  static func listIdentity(of diskData: [String: Any]) -> String {
    let size = (diskData["Size"] as? Int64).map(String.init) ?? "?"
    let content = diskData["Content"] as? String ?? ""
    let partitions = (diskData["Partitions"] as? [[String: Any]] ?? []).map {
      "\($0["Content"] as? String ?? ""):\(($0["Size"] as? Int64).map(String.init) ?? "?")"
    }
    return "\(size)|\(content)|\(partitions.joined(separator: ","))"
  }

  /// Info for `disks`. `completion` runs on the calling thread when every
  /// disk is served from the cache, otherwise on `queue` once all fetches
  /// have finished. Entries of disks not in `disks` are forgotten, so a
  /// reused BSD name never inherits the info of a disk that went away.
  func lookup(_ disks: [Disk], completion: @escaping (Lookup) -> Void) {
    var result = Lookup()
    var toFetch: [Disk] = []

    lock.withLock {
      let present = Set(disks.map(\.identifier))
      entries = entries.filter { present.contains($0.key) }
      let current = now()
      for disk in disks {
        if let entry = entries[disk.identifier], entry.identity == disk.identity,
          current.timeIntervalSince(entry.fetchedAt) < ttl
        {
          result.info[disk.identifier] = entry.info
          result.reused.insert(disk.identifier)
        } else {
          toFetch.append(disk)
        }
      }
    }

    guard !toFetch.isEmpty else {
      completion(result)
      return
    }

    let group = DispatchGroup()
    let fetchedLock = NSLock()
    var fetchedInfo: [String: [String: Any]] = [:]
    for disk in toFetch {
      group.enter()
      queue.async {
        if let info = self.fetch(disk.identifier) {
          fetchedLock.withLock { fetchedInfo[disk.identifier] = info }
        }
        group.leave()
      }
    }

    group.notify(queue: queue) {
      self.lock.withLock {
        let fetchedAt = self.now()
        for disk in toFetch {
          result.fetched.insert(disk.identifier)
          if let info = fetchedInfo[disk.identifier] {
            self.entries[disk.identifier] = Entry(
              info: info, identity: disk.identity, fetchedAt: fetchedAt)
            result.info[disk.identifier] = info
          } else if let entry = self.entries[disk.identifier], entry.identity == disk.identity {
            // Keep the old timestamp so the next refresh tries again.
            Log.drive.error(
              "diskutil info failed for \(disk.identifier, privacy: .public); using cached disk information."
            )
            result.info[disk.identifier] = entry.info
          } else {
            Log.drive.error(
              "diskutil info failed for \(disk.identifier, privacy: .public) and nothing is cached."
            )
            self.entries[disk.identifier] = nil
            result.unclassified.insert(disk.identifier)
          }
        }
      }
      completion(result)
    }
  }
}
