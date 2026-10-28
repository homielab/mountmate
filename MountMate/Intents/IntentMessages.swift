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

  /// `reasons` (one per line, each naming its disk) follow the names.
  static func ejectFailure(
    names: [String], reasons: [String] = [], localize: Localize = defaultLocalize
  ) -> String {
    let message = String(format: localize("Could not eject: %@"), names.joined(separator: ", "))
    return reasons.isEmpty ? message : message + "\n" + reasons.joined(separator: "\n")
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

  static func shareUnmounted(name: String, localize: Localize = defaultLocalize) -> String {
    String(format: localize("“%@” unmounted."), name)
  }

  /// `reason` is the already sanitized error of the unmount, when there is one.
  static func shareUnmountFailure(
    name: String, reason: String?, localize: Localize = defaultLocalize
  ) -> String {
    guard let reason, !reason.isEmpty else {
      return String(format: localize("Could not unmount “%@”."), name)
    }
    return String(format: localize("Could not unmount “%@”: %@"), name, reason)
  }

  static func sharesMounted(localize: Localize = defaultLocalize) -> String {
    localize("Network shares mounted.")
  }

  static func sharesUnmounted(localize: Localize = defaultLocalize) -> String {
    localize("Network shares unmounted.")
  }

  /// Error text when several shares failed: their names, then one reason per
  /// line (each reason names its share).
  static func bulkShareFailure(
    names: [String], mount: Bool, reasons: [String], localize: Localize = defaultLocalize
  ) -> String {
    let summary = volumeFailure(names: names, mount: mount, localize: localize)
    let lines = reasons.filter { !$0.isEmpty }
    return lines.isEmpty ? summary : summary + "\n\n" + lines.joined(separator: "\n")
  }

  static func volumeNotFound(name: String, localize: Localize = defaultLocalize) -> String {
    String(format: localize("No volume named “%@”."), name)
  }

  static func volumeNameAmbiguous(name: String, localize: Localize = defaultLocalize) -> String {
    String(format: localize("More than one volume is named “%@”."), name)
  }

  static func volumeProtected(name: String, localize: Localize = defaultLocalize) -> String {
    String(format: localize("“%@” is protected and cannot be unmounted."), name)
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
