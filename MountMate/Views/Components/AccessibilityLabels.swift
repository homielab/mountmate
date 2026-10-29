//  Created by homielab.com

import Foundation

/// VoiceOver labels of the row action buttons: the verb plus the name of
/// the volume, disk or share the button acts on, so that rows sound
/// different when several are listed. The formatting lives over the
/// "<Verb> “%@”" localization keys; `AccessibilityLabelsTests` locks them
/// for every language, including names that contain quotes.
enum AccessibilityLabels {
  enum Action: String, CaseIterable {
    case eject = "Eject"
    case mount = "Mount"
    case unmount = "Unmount"
    case edit = "Edit"
    case delete = "Delete"
    case openInFinder = "Open in Finder"

    /// Localization key of the "<Verb> “%@”" format string.
    var formatKey: String {
      switch self {
      case .eject: return "Eject “%@”"
      case .mount: return "Mount “%@”"
      case .unmount: return "Unmount “%@”"
      case .edit: return "Edit “%@”"
      case .delete: return "Delete “%@”"
      case .openInFinder: return "Open in Finder “%@”"
      }
    }
  }

  /// Localized label for an action button, e.g. `Eject “Backup”`.
  /// Speech-safe for any name: the name is a format argument, so quotes
  /// in it must not change the sentence.
  static func action(_ action: Action, name: String, bundle: Bundle = .main) -> String {
    String(
      format: NSLocalizedString(
        action.formatKey, bundle: bundle,
        comment: "Accessibility label of the \(action.rawValue) button"),
      name)
  }

  /// Label of a keyboard shortcut recorder, naming the action it sets so
  /// the recorders in Settings sound different, e.g.
  /// `Shortcut for “Mount All Volumes”`. The recorder's value is the
  /// shortcut itself (or "Not Set").
  static func shortcutRecorder(name: String, bundle: Bundle = .main) -> String {
    String(
      format: NSLocalizedString(
        "Shortcut for “%@”", bundle: bundle,
        comment: "Accessibility label of a keyboard shortcut recorder; %@ is the action"),
      name)
  }

  /// VoiceOver value of a row that expands and collapses, e.g. a disk
  /// header: "Expanded" or "Collapsed".
  static func expansionValue(isExpanded: Bool, bundle: Bundle = .main) -> String {
    isExpanded
      ? NSLocalizedString(
        "Accessibility Expanded", bundle: bundle,
        comment: "Accessibility value of a disk row whose volumes are shown")
      : NSLocalizedString(
        "Accessibility Collapsed", bundle: bundle,
        comment: "Accessibility value of a disk row whose volumes are hidden")
  }
}
