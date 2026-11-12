//  Created by homielab.com

import Foundation

/// Decides which network shares "Also Unmount Network Shares" takes away
/// when the Mac sleeps or the screen locks. Pure: the app delegate acts on
/// the answer.
enum NetworkShareSleepRules {
  /// Settings → General → Behavior; off unless the user turned it on.
  static let enabledKey = "unmountSharesWithDisksEnabled"

  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: enabledKey)
  }

  /// The saved shares to unmount: mounted now and not kept mounted by Keep
  /// Alive (like the disks), in their saved order. Nothing when the setting
  /// is off, so shares stay untouched by default. A share the user already
  /// unmounted is not mounted, so it is never in the list (and never comes
  /// back on wake).
  static func candidates(
    isEnabled: Bool, shares: [NetworkShare], mountedIDs: Set<UUID>
  ) -> [NetworkShare] {
    guard isEnabled else { return [] }
    return shares.filter { mountedIDs.contains($0.id) && !$0.keepMounted }
  }
}
