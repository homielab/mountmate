//  Created by homielab.com

import Foundation

/// Decides whether a network share status refresh also reads each mounted
/// share's capacity (`statfs`, a round trip to the server).
///
/// Keep Alive sweeps and network-change remounts only need to know which
/// shares are mounted; reading capacity every 30 seconds would keep a NAS
/// from ever spinning down. Capacity is read for the popover, Settings and
/// mount events, and at most once a minute unless a mounted share has no
/// capacity yet.
enum ShareUsageReadRules {
  /// A capacity read younger than this is reused instead of asking the
  /// server again.
  static let minimumInterval: TimeInterval = 60

  /// - Parameters:
  ///   - requested: the caller wants capacity (false for Keep Alive).
  ///   - mountedShareIDs: shares the mount table lists right now.
  ///   - knownUsageIDs: shares with a capacity from an earlier read.
  ///   - lastReadAt: when the last capacity read started, if any.
  static func shouldRead(
    requested: Bool, mountedShareIDs: Set<UUID>, knownUsageIDs: Set<UUID>,
    lastReadAt: Date?, now: Date
  ) -> Bool {
    guard requested, !mountedShareIDs.isEmpty else { return false }
    // A share that just mounted (or never answered) has no ring yet.
    guard mountedShareIDs.isSubset(of: knownUsageIDs), let lastReadAt else { return true }
    return now.timeIntervalSince(lastReadAt) >= minimumInterval
  }
}
