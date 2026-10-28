//  Created by homielab.com

import XCTest

@testable import MountMate

/// The row buttons' accessibility labels say "<Verb> “<name>”" ("Eject
/// “Backup”") so VoiceOver tells rows apart. These tests lock the
/// localization keys of all seven languages and the formatting, including
/// names that contain quotes.
final class AccessibilityLabelsTests: XCTestCase {
  private let languages = ["en", "fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"]

  private func languageBundle(_ language: String) throws -> Bundle {
    let lproj = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"),
      "missing \(language).lproj")
    return try XCTUnwrap(Bundle(path: lproj), "unreadable \(language).lproj")
  }

  func testFormatKeysMatchTheStringsTable() {
    XCTAssertEqual(AccessibilityLabels.Action.eject.formatKey, "Eject “%@”")
    XCTAssertEqual(AccessibilityLabels.Action.mount.formatKey, "Mount “%@”")
    XCTAssertEqual(AccessibilityLabels.Action.unmount.formatKey, "Unmount “%@”")
    XCTAssertEqual(AccessibilityLabels.Action.edit.formatKey, "Edit “%@”")
    XCTAssertEqual(AccessibilityLabels.Action.delete.formatKey, "Delete “%@”")
    XCTAssertEqual(AccessibilityLabels.Action.openInFinder.formatKey, "Open in Finder “%@”")
  }

  /// A name is inserted wherever the verb and its quotes are, and the name
  /// itself never ends up rewritten by the format string.
  func testEveryLanguageHasEveryActionKeyAndFormatsTheName() throws {
    for language in languages {
      let bundle = try languageBundle(language)
      for action in AccessibilityLabels.Action.allCases {
        let template = bundle.localizedString(
          forKey: action.formatKey, value: "<missing>", table: nil)
        XCTAssertNotEqual(template, "<missing>", "\(language): \(action.formatKey)")
        XCTAssertTrue(template.contains("%@"), "\(language): %@ in \(action.formatKey)")

        let name = #"Big “Server” "Path""#
        let label = String(format: template, name)
        XCTAssertTrue(label.contains(name), "\(language): \(action.formatKey) keeps the name")
        XCTAssertFalse(
          label.contains("%"), "\(language): no stray % left in \(action.formatKey)")
      }
    }
  }

  /// Locks that `action(_:name:)` formats the localized template; spoken
  /// through the English bundle so the result is deterministic.
  func testActionCombinesVerbAndName() throws {
    let english = try languageBundle("en")
    let label = AccessibilityLabels.action(.eject, name: "meostorage", bundle: english)
    XCTAssertEqual(label, "Eject “meostorage”")
    XCTAssertEqual(
      AccessibilityLabels.action(.mount, name: "“NAS”", bundle: english),
      String(
        format: english.localizedString(forKey: "Mount “%@”", value: "<missing>", table: nil),
        "“NAS”"))
    XCTAssertEqual(
      AccessibilityLabels.action(.openInFinder, name: "NAS", bundle: english),
      "Open in Finder “NAS”")
  }

  /// The language picker names Traditional Chinese in Traditional script
  /// (繁體, not the Simplified 繁体) wherever the label is shown untranslated.
  func testTraditionalChineseLabelUsesTraditionalScript() throws {
    let zhHant = try languageBundle("zh-Hant")
    XCTAssertEqual(
      zhHant.localizedString(forKey: "中文（繁體）", value: "<missing>", table: nil), "中文（繁體）")
    for language in languages {
      let bundle = try languageBundle(language)
      XCTAssertEqual(
        bundle.localizedString(forKey: "中文（繁体）", value: "<missing>", table: nil), "<missing>",
        "\(language): the Simplified-script key is gone")
    }
  }
}
