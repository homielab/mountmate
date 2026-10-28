//  Created by homielab.com

import Foundation

/// Which saved network shares "Mount All Saved Shares" and "Unmount All Saved
/// Shares" act on, and how their failures are listed. Pure, so it is testable
/// without a server.
enum SavedShareBulkRules {
  struct Candidates: Equatable {
    /// Saved shares that are not mounted, in their saved order.
    let mount: [NetworkShare]
    /// Saved shares that are mounted, in their saved order.
    let unmount: [NetworkShare]
  }

  static func candidates(shares: [NetworkShare], mountedIDs: Set<UUID>) -> Candidates {
    Candidates(
      mount: shares.filter { !mountedIDs.contains($0.id) },
      unmount: shares.filter { mountedIDs.contains($0.id) })
  }

  /// One line per share that could not be mounted, naming it, with the
  /// reason when there is one.
  static func mountFailureReasons(
    _ failures: [NetworkMountManager.ShareMountFailure],
    localize: IntentMessages.Localize = IntentMessages.defaultLocalize
  ) -> [String] {
    failures.map {
      IntentMessages.shareFailure(name: $0.name, reason: $0.reason, localize: localize)
    }
  }
}
