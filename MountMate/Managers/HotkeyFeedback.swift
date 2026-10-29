//  Created by homielab.com

import Foundation

/// The short confirmation shown after a global keyboard shortcut ran
/// "Unmount All", "Mount All", "Eject All External Disks" or Mount / Unmount
/// All Network Shares. The menu is
/// usually closed then, so without it a press that did nothing looks the
/// same as one that worked. Pure: `bundle` and `locale` let tests pick a
/// language.
enum HotkeyFeedback {
  /// "Unmounted 3 volumes", "Nothing to mount", "Ejected 1 disk, 1 failed"…
  /// - Parameter succeeded: volumes (disks for Eject All, shares for the
  ///   network share actions) the action handled.
  /// - Parameter failed: the ones that could not be handled.
  static func message(
    action: HotkeyAction, succeeded: Int, failed: Int, bundle: Bundle = .main,
    locale: Locale = .current
  ) -> String {
    let keys = Keys(action)
    func plural(_ key: String, _ count: Int) -> String {
      PluralizedString.format(key, count, bundle: bundle, locale: locale)
    }
    switch (succeeded > 0, failed > 0) {
    case (false, false):
      return bundle.localizedString(forKey: keys.nothing, value: keys.nothing, table: nil)
    case (true, false):
      return plural(keys.done, succeeded)
    case (false, true):
      return plural(keys.allFailed, failed)
    case (true, true):
      let format = bundle.localizedString(
        forKey: "hotkey.feedback.mixed", value: "%1$@, %2$@", table: nil)
      return String(
        format: format, locale: locale, plural(keys.done, succeeded),
        plural("hotkey.failed", failed))
    }
  }

  /// SF Symbol for the HUD: a warning when something failed, an info sign
  /// when there was nothing to do.
  static func systemImage(succeeded: Int, failed: Int) -> String {
    if failed > 0 { return "exclamationmark.triangle.fill" }
    return succeeded > 0 ? "checkmark.circle.fill" : "info.circle.fill"
  }

  /// Icon colour: orange when something failed, grey when there was
  /// nothing to do, green only when everything worked.
  static func tint(succeeded: Int, failed: Int) -> HUDTint {
    if failed > 0 { return .warning }
    return succeeded > 0 ? .success : .neutral
  }

  private struct Keys {
    let nothing: String
    let done: String
    let allFailed: String

    init(_ action: HotkeyAction) {
      switch action {
      case .unmountAll:
        nothing = "Nothing to unmount"
        done = "hotkey.unmounted"
        allFailed = "hotkey.unmount.failed"
      case .mountAll:
        nothing = "Nothing to mount"
        done = "hotkey.mounted"
        allFailed = "hotkey.mount.failed"
      case .ejectAll:
        nothing = "Nothing to eject"
        done = "hotkey.ejected"
        allFailed = "hotkey.eject.failed"
      case .mountAllShares:
        nothing = "No network shares to mount"
        done = "hotkey.shares.mounted"
        allFailed = "hotkey.shares.mount.failed"
      case .unmountAllShares:
        nothing = "No network shares to unmount"
        done = "hotkey.shares.unmounted"
        allFailed = "hotkey.shares.unmount.failed"
      }
    }
  }
}
