//  Created by homielab.com

import Foundation

/// Retry bookkeeping for keep-alive targets: how many times each target was
/// retried in a row and when it may be tried again. Not thread-safe; the
/// owner serializes access. The clock is injectable so tests need no sleeping.
struct RetryBook<Key: Hashable> {
  struct Entry: Equatable {
    var attempt: Int = 0
    var nextFireDate: Date?
  }

  private(set) var entries: [Key: Entry] = [:]
  private let now: () -> Date

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  /// Counts one more attempt for `key` and schedules the next one after
  /// `backoff(attempt)` seconds.
  mutating func recordAttempt(_ key: Key, backoff: (Int) -> TimeInterval) {
    var entry = entries[key] ?? Entry()
    entry.attempt += 1
    entry.nextFireDate = now().addingTimeInterval(backoff(entry.attempt))
    entries[key] = entry
  }

  /// A key is due when it was never attempted or its backoff has elapsed.
  func isDue(_ key: Key) -> Bool {
    guard let fireDate = entries[key]?.nextFireDate else { return true }
    return now() >= fireDate
  }

  func attempt(for key: Key) -> Int { entries[key]?.attempt ?? 0 }

  func nextFireDate(for key: Key) -> Date? { entries[key]?.nextFireDate }

  mutating func remove(_ key: Key) { entries.removeValue(forKey: key) }

  mutating func removeAll() { entries.removeAll() }

  /// Makes every key due right away. Attempt counts are kept, so a key that
  /// keeps failing backs off again from where it was.
  mutating func clearDelays() {
    for key in entries.keys { entries[key]?.nextFireDate = nil }
  }

  /// Drops every key not in `valid`; returns the dropped keys.
  @discardableResult
  mutating func prune(keeping valid: Set<Key>) -> Set<Key> {
    let stale = Set(entries.keys).subtracting(valid)
    for key in stale { entries.removeValue(forKey: key) }
    return stale
  }
}
