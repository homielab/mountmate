//  Created by homielab.com

import Foundation

/// Decides whether a network share status refresh also reads each mounted
/// share's capacity (`statfs`, a round trip to the server).
///
/// Keep Alive sweeps and network-change remounts only need to know which
/// shares are mounted; reading capacity every 30 seconds would keep a NAS
/// from ever spinning down. Capacity is read for the popover, Settings and
/// mount events, and at most once a minute unless a share mounted since the
/// last read. A share whose read failed or timed out waits for the next
/// minute like the others, so one unreachable server does not make every
/// popover or Settings refresh ask all servers again.
enum ShareUsageReadRules {
  /// A capacity read younger than this is reused instead of asking the
  /// server again.
  static let minimumInterval: TimeInterval = 60

  /// - Parameters:
  ///   - requested: the caller wants capacity (false for Keep Alive).
  ///   - mountedShareIDs: shares the mount table lists right now.
  ///   - attemptedShareIDs: shares the last read asked for, whether or not
  ///     they answered.
  ///   - lastReadAt: when the last capacity read started, if any.
  static func shouldRead(
    requested: Bool, mountedShareIDs: Set<UUID>, attemptedShareIDs: Set<UUID>,
    lastReadAt: Date?, now: Date
  ) -> Bool {
    guard requested, !mountedShareIDs.isEmpty else { return false }
    // A share that mounted after the last read has no ring yet.
    guard mountedShareIDs.isSubset(of: attemptedShareIDs), let lastReadAt else { return true }
    return now.timeIntervalSince(lastReadAt) >= minimumInterval
  }
}
