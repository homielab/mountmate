//  Created by homielab.com

import Foundation

/// Orders overlapping runs of the same refresh so an older result never
/// replaces a newer one. Each run takes a ticket when it starts and may
/// publish its result only if no run started after it has published yet;
/// results that arrive late are dropped.
///
/// A value type without locking: keep it on one thread (the main thread).
struct LatestResultGate: Sendable {
  private(set) var lastIssued = 0
  private(set) var lastApplied = 0

  /// A ticket for a run starting now; newer runs get larger tickets.
  mutating func begin() -> Int {
    lastIssued += 1
    return lastIssued
  }

  /// Whether the result of the run holding `ticket` may be published.
  /// Records it as the latest published result when it may.
  mutating func shouldApply(_ ticket: Int) -> Bool {
    guard ticket > lastApplied else { return false }
    lastApplied = ticket
    return true
  }
}
