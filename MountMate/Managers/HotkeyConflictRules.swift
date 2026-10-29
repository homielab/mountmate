//  Created by homielab.com

import Foundation

/// Finds a shortcut that would clash with another MountMate action. Two
/// actions on one key combination can't both register, and the failure
/// would otherwise look like another app holding the key.
enum HotkeyConflictRules {
  /// The other action that already uses `shortcut`, if any. Reassigning an
  /// action its own shortcut is not a conflict.
  static func conflict(
    for shortcut: HotkeyShortcut, assignedTo action: HotkeyAction,
    among assigned: [HotkeyAction: HotkeyShortcut]
  ) -> HotkeyAction? {
    HotkeyAction.allCases.first { other in
      other != action && assigned[other] == shortcut
    }
  }

  /// Actions whose shortcut repeats one of an earlier action (in
  /// `HotkeyAction.allCases` order), mapped to that earlier action. Older
  /// versions could save such pairs; only the first one is registered.
  static func duplicates(among assigned: [HotkeyAction: HotkeyShortcut]) -> [HotkeyAction:
    HotkeyAction]
  {
    var result: [HotkeyAction: HotkeyAction] = [:]
    let actions = HotkeyAction.allCases
    for (index, action) in actions.enumerated() {
      guard let shortcut = assigned[action] else { continue }
      if let first = actions[..<index].first(where: { assigned[$0] == shortcut }) {
        result[action] = first
      }
    }
    return result
  }
}

extension HotkeyAction {
  /// The action's name as shown in Settings.
  var localizedName: String {
    switch self {
    case .unmountAll:
      return NSLocalizedString("Unmount All Volumes", comment: "Keyboard shortcut action")
    case .mountAll:
      return NSLocalizedString("Mount All Volumes", comment: "Keyboard shortcut action")
    case .ejectAll:
      return NSLocalizedString("Eject All External Disks", comment: "Keyboard shortcut action")
    case .mountAllShares:
      return NSLocalizedString("Mount All Network Shares", comment: "Keyboard shortcut action")
    case .unmountAllShares:
      return NSLocalizedString("Unmount All Network Shares", comment: "Keyboard shortcut action")
    }
  }
}
