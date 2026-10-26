//  Created by homielab.com

import Foundation

/// Texts Shortcuts shows after an intent ran. Pure, so the wording is testable
/// without the app running; `localize` lets tests pick a language.
enum IntentMessages {
  typealias Localize = (String) -> String

  static let defaultLocalize: Localize = { NSLocalizedString($0, comment: "Shortcuts result") }

  static func volumesMounted(localize: Localize = defaultLocalize) -> String {
    localize("Volumes mounted.")
  }

  static func volumesUnmounted(localize: Localize = defaultLocalize) -> String {
    localize("Volumes unmounted.")
  }

  static func disksEjected(localize: Localize = defaultLocalize) -> String {
    localize("Disks ejected.")
  }

  static func ejectFailure(names: [String], localize: Localize = defaultLocalize) -> String {
    String(format: localize("Could not eject: %@"), names.joined(separator: ", "))
  }

  static func shareMounted(name: String, localize: Localize = defaultLocalize) -> String {
    String(format: localize("“%@” mounted."), name)
  }

  /// Error text for volumes that failed to mount (`mount == true`) or unmount.
  static func volumeFailure(
    names: [String], mount: Bool, localize: Localize = defaultLocalize
  ) -> String {
    let format = localize(mount ? "Could not mount: %@" : "Could not unmount: %@")
    return String(format: format, names.joined(separator: ", "))
  }

  /// `reason` is the already sanitized error of the mount, when there is one.
  static func shareFailure(
    name: String, reason: String?, localize: Localize = defaultLocalize
  ) -> String {
    guard let reason, !reason.isEmpty else {
      return String(format: localize("Could not mount “%@”."), name)
    }
    return String(format: localize("Could not mount “%@”: %@"), name, reason)
  }

  static func shareNotFound(localize: Localize = defaultLocalize) -> String {
    localize("That network share is no longer saved in MountMate.")
  }
}

/// A failed intent; Shortcuts shows `errorDescription`.
struct IntentFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
