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

  // MARK: - Decorative icons

  private func source(_ relativePath: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("MountMate/\(relativePath)")
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// True when `.accessibilityHidden(true)` follows `anchor` within the next
  /// few lines, i.e. in the modifier chain of that image (or its container).
  static func isHidden(after anchor: String, in text: String, within lines: Int = 5) -> Bool {
    guard let range = text.range(of: anchor) else { return false }
    let following = text[range.upperBound...].split(
      separator: "\n", omittingEmptySubsequences: false)
    return following.prefix(lines + 1).contains { $0.contains(".accessibilityHidden(true)") }
  }

  func testIsHiddenLooksOnlyAtTheNextFewLines() {
    let text = "Image(systemName: \"a\")\n  .font(.title)\n  .accessibilityHidden(true)\n"
    XCTAssertTrue(Self.isHidden(after: "\"a\"", in: text))
    XCTAssertFalse(Self.isHidden(after: "\"a\"", in: text, within: 0))
    XCTAssertFalse(Self.isHidden(after: "\"missing\"", in: text))
  }

  /// Icons next to a text that already says the same thing are skipped by
  /// VoiceOver, so it doesn't read "exclamationmark triangle" before an error.
  func testDecorativeIconsAreHiddenFromVoiceOver() throws {
    let icons: [(file: String, anchor: String)] = [
      (
        "Views/Components/ErrorBannerView.swift",
        "Image(systemName: \"exclamationmark.triangle.fill\")"
      ),
      ("Views/Main/ErrorView.swift", "Image(systemName: \"exclamationmark.triangle.fill\")"),
      ("Views/Main/MainView.swift", "Image(systemName: \"externaldrive.fill.badge.questionmark\")"),
      ("Views/Settings/NetworkSharesSettingsView.swift", "Image(systemName: \"server.rack\")"),
      (
        "Views/Settings/EditNetworkShareSheet.swift",
        "Image(systemName: \"externaldrive.connected.to.line.below\")"
      ),
      (
        "Views/Settings/EditNetworkShareSheet.swift",
        "Image(systemName: \"exclamationmark.triangle.fill\")"
      ),
      ("Views/Settings/NetworkServicePickerSheet.swift", "Image(systemName: \"wifi\")"),
      ("Views/Settings/NetworkServicePickerSheet.swift", "Image(systemName: \"chevron.right\")"),
      ("Views/Settings/NetworkServicePickerSheet.swift", "Image(systemName: systemImage)"),
    ]
    for icon in icons {
      let text = try source(icon.file)
      XCTAssertTrue(
        Self.isHidden(after: icon.anchor, in: text), "\(icon.file): \(icon.anchor) is not hidden")
    }
  }

  /// The error banner, the error screen and the loading screen each read as
  /// one VoiceOver element.
  func testStatusViewsReadAsOneElement() throws {
    for file in [
      "Views/Components/ErrorBannerView.swift", "Views/Main/ErrorView.swift",
      "Views/Main/LoadingView.swift",
    ] {
      XCTAssertTrue(
        try source(file).contains(".accessibilityElement(children: .combine)"),
        "\(file) is not combined")
    }
  }

  // MARK: - Disk header row

  /// A disk header tells VoiceOver whether its volumes are shown, in every
  /// language.
  func testExpansionValueIsLocalizedInEveryLanguage() throws {
    let english = try languageBundle("en")
    XCTAssertEqual(
      AccessibilityLabels.expansionValue(isExpanded: true, bundle: english), "Expanded")
    XCTAssertEqual(
      AccessibilityLabels.expansionValue(isExpanded: false, bundle: english), "Collapsed")
    for language in languages {
      let bundle = try languageBundle(language)
      let expanded = AccessibilityLabels.expansionValue(isExpanded: true, bundle: bundle)
      let collapsed = AccessibilityLabels.expansionValue(isExpanded: false, bundle: bundle)
      XCTAssertFalse(expanded.hasPrefix("Accessibility "), "\(language): Expanded is missing")
      XCTAssertFalse(collapsed.hasPrefix("Accessibility "), "\(language): Collapsed is missing")
      XCTAssertNotEqual(expanded, collapsed, "\(language)")
    }
  }

  /// The disk header expands and collapses with the mouse, the keyboard and
  /// VoiceOver: a button with an Expanded/Collapsed value, a default action
  /// and Return/Space, while the chevron stays silent.
  func testDiskHeaderTogglesForKeyboardAndVoiceOver() throws {
    let text = try source("Views/Main/DiskHeaderRow.swift")
    for snippet in [
      ".accessibilityAddTraits(.isButton)",
      ".accessibilityValue(Text(AccessibilityLabels.expansionValue(isExpanded: isExpanded)))",
      ".accessibilityAction { toggleExpanded() }",
      ".onTapGesture { toggleExpanded() }",
      ".rowKeyboardNavigation(primaryAction: toggleExpanded)",
    ] {
      XCTAssertTrue(text.contains(snippet), "DiskHeaderRow is missing \(snippet)")
    }
    XCTAssertTrue(
      Self.isHidden(after: "Image(systemName: \"chevron.right\")", in: text, within: 6),
      "the disk header chevron is not hidden")
  }
}
