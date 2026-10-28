import XCTest

@testable import MountMate

/// Every language must translate the same keys as English, so no string
/// falls back to English in one language only.
final class LocalizationKeyParityTests: XCTestCase {
  private let languages = ["en", "fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"]

  private func keys(_ language: String, table: String, type: String) throws -> Set<String> {
    let lproj = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"),
      "missing \(language).lproj")
    let url = URL(fileURLWithPath: lproj).appendingPathComponent("\(table).\(type)")
    let dictionary = try XCTUnwrap(
      NSDictionary(contentsOf: url) as? [String: Any], "unreadable \(url.path)")
    return Set(dictionary.keys)
  }

  func testAllLanguagesHaveTheSameStringKeys() throws {
    let english = try keys("en", table: "Localizable", type: "strings")
    XCTAssertFalse(english.isEmpty)
    for language in languages.dropFirst() {
      let other = try keys(language, table: "Localizable", type: "strings")
      XCTAssertEqual(
        other.subtracting(english).sorted(), [], "\(language): keys not in English")
      XCTAssertEqual(english.subtracting(other).sorted(), [], "\(language): missing keys")
    }
  }

  func testAllLanguagesHaveTheSameShortcutPhrases() throws {
    let english = try keys("en", table: "AppShortcuts", type: "strings")
    XCTAssertFalse(english.isEmpty)
    for language in languages.dropFirst() {
      XCTAssertEqual(
        try keys(language, table: "AppShortcuts", type: "strings"), english, language)
    }
  }

  func testAllLanguagesHaveTheSamePluralKeys() throws {
    let english = try keys("en", table: "Localizable", type: "stringsdict")
    for language in languages.dropFirst() {
      XCTAssertEqual(
        try keys(language, table: "Localizable", type: "stringsdict"), english, language)
    }
  }

  /// The permission prompts macOS shows (removable volumes, local network)
  /// come from InfoPlist.strings, so every language must translate every
  /// usage description in Info.plist, and English must say what Info.plist says.
  func testAllLanguagesTranslateThePermissionPrompts() throws {
    let infoPlistURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("MountMate/Info.plist")
    let infoPlist = try XCTUnwrap(NSDictionary(contentsOf: infoPlistURL) as? [String: Any])
    let usageKeys = Set(infoPlist.keys.filter { $0.hasSuffix("UsageDescription") })
    XCTAssertEqual(
      usageKeys, ["NSRemovableVolumesUsageDescription", "NSLocalNetworkUsageDescription"])

    for language in languages {
      XCTAssertEqual(try keys(language, table: "InfoPlist", type: "strings"), usageKeys, language)
    }

    let lproj = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: "en", ofType: "lproj"))
    let english = try XCTUnwrap(
      NSDictionary(
        contentsOf: URL(fileURLWithPath: lproj).appendingPathComponent("InfoPlist.strings"))
        as? [String: String])
    for key in usageKeys {
      XCTAssertEqual(english[key], infoPlist[key] as? String, key)
    }
  }

  /// Format arguments (`%@`, `%d`, `%lld`, `%1$@`…) of a string as
  /// `position:specifier`, sorted. Plain placeholders count up in order, so
  /// "%@ … %@" equals "%1$@ … %2$@", while a translation that changes the
  /// type or the number of arguments differs. `%%` is not an argument.
  static func placeholders(in text: String) -> [String] {
    let pattern =
      "%(?:(\\d+)\\$)?[-+ #0]*\\d*(?:\\.\\d+)?((?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSp%])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsText = text as NSString
    var next = 1
    var result: [String] = []
    for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
      let specifier = nsText.substring(with: match.range(at: 2))
      if specifier == "%" { continue }
      let position: String
      if match.range(at: 1).location != NSNotFound {
        position = nsText.substring(with: match.range(at: 1))
      } else {
        position = String(next)
        next += 1
      }
      result.append("\(position):\(specifier)")
    }
    return result.sorted()
  }

  /// Placeholder differences between English and `language`, one line per key.
  private func placeholderMismatches(for language: String) throws -> [String] {
    func strings(_ language: String) throws -> [String: String] {
      let lproj = try XCTUnwrap(
        Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"))
      let url = URL(fileURLWithPath: lproj).appendingPathComponent("Localizable.strings")
      return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }
    let english = try strings("en")
    let other = try strings(language)
    return english.keys.sorted().compactMap { key in
      guard let translated = other[key] else { return nil }
      let expected = Self.placeholders(in: english[key] ?? "")
      let actual = Self.placeholders(in: translated)
      return expected == actual ? nil : "\(key): \(expected) vs \(actual)"
    }
  }

  func testAllLanguagesKeepTheEnglishPlaceholders() throws {
    for language in languages.dropFirst() {
      XCTAssertEqual(try placeholderMismatches(for: language), [], language)
    }
  }

  func testPlaceholderExtractionSeesChangedArguments() {
    XCTAssertEqual(Self.placeholders(in: "Mounted %@ of %lld (100%%)"), ["1:@", "2:lld"])
    XCTAssertEqual(Self.placeholders(in: "%2$@ then %1$@"), ["1:@", "2:@"])
    XCTAssertEqual(Self.placeholders(in: "%@ of %@"), Self.placeholders(in: "%1$@ / %2$@"))
    XCTAssertNotEqual(
      Self.placeholders(in: "Could not eject: %@"), Self.placeholders(in: "Không thể đẩy ra: %d"))
    XCTAssertNotEqual(
      Self.placeholders(in: "%1$@ and %2$@"), Self.placeholders(in: "%1$@"))
  }

  /// Keys declared more than once in the raw text of a `.strings` file,
  /// sorted. A later duplicate silently wins when the file is loaded, so a
  /// translation edited at one place can be overridden at the other.
  static func duplicateKeys(inStringsText text: String) -> [String] {
    let pattern = "^\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*="
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    else { return [] }
    let nsText = text as NSString
    var counts: [String: Int] = [:]
    for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
      counts[nsText.substring(with: match.range(at: 1)), default: 0] += 1
    }
    return counts.filter { $0.value > 1 }.keys.sorted()
  }

  func testDuplicateKeyDetectionSeesRepeatedKeys() {
    let sample = """
      /* comment */
      "A" = "one";
      "B %@" = "two";
      "A" = "three";
      "Say \\"hi\\"" = "x";
      "Say \\"hi\\"" = "y";
      """
    XCTAssertEqual(Self.duplicateKeys(inStringsText: sample), ["A", "Say \\\"hi\\\""])
    XCTAssertEqual(Self.duplicateKeys(inStringsText: "\"A\" = \"1\";\n\"B\" = \"2\";"), [])
  }

  func testNoLanguageDeclaresADuplicateKey() throws {
    for language in languages {
      // The bundled copy is compiled to a binary plist, so read the source file.
      let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MountMate/Resources/\(language).lproj/Localizable.strings")
      for table in ["Localizable", "InfoPlist"] {
        let file = url.deletingLastPathComponent().appendingPathComponent("\(table).strings")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(
          Self.duplicateKeys(inStringsText: text), [], "\(language) \(table): duplicate keys")
      }
    }
  }

  /// A key as it is written in a Swift string literal.
  static func escapedForSwiftLiteral(_ key: String) -> String {
    key.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
  }

  func testEscapedKeyMatchesSwiftLiteralForm() {
    XCTAssertEqual(Self.escapedForSwiftLiteral("Say \"hi\"\n"), "Say \\\"hi\\\"\\n")
  }

  /// A key no Swift file mentions is dead text: the screen that used it
  /// lost its call site (for example an alert that was not carried over
  /// when a view was split), so translators keep translating it for nothing.
  func testEveryEnglishKeyIsUsedInSource() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
    let sourceRoot = root.appendingPathComponent("MountMate")
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
    var source = ""
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      source += try String(contentsOf: url, encoding: .utf8)
    }
    XCTAssertFalse(source.isEmpty)

    let english = try XCTUnwrap(
      NSDictionary(
        contentsOf: root.appendingPathComponent("MountMate/Resources/en.lproj/Localizable.strings"))
        as? [String: Any])
    // System keys are read by macOS, not by our code. The two others were
    // already unused when this test was added; delete them (in every
    // language) rather than adding to this list.
    let knownUnused: Set<String> = [
      "Preview: %@",
      "Could not read storage details. Please grant MountMate 'Full Disk Access' or"
        + " 'Files and Folders' permissions in System Settings > Privacy & Security.",
    ]
    let unused = english.keys.sorted().filter { key in
      !key.hasPrefix("CFBundle") && !knownUnused.contains(key)
        && !source.contains(Self.escapedForSwiftLiteral(key))
    }
    XCTAssertEqual(unused, [], "English keys that no Swift file uses")
  }

  func testNewErrorStringsKeepTheirArguments() throws {
    for language in languages {
      let lproj = try XCTUnwrap(
        Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: lproj))
      for (key, placeholders) in [
        (
          "Cannot create mount point at “%1$@”.\n\nThis location requires administrator privileges."
            + " Please use a path within your home folder (e.g., ~/mountmate/%2$@) or leave the"
            + " Custom Mount Point empty to use the default location.",
          ["%1$@", "%2$@"]
        ),
        ("Failed to create mount point at “%1$@”: %2$@", ["%1$@", "%2$@"]),
        (
          "Could not mount “%1$@” at “%2$@”.\n\nThe mount location requires administrator"
            + " privileges. Please use a path within your home folder (e.g., ~/mountmate/%1$@) or"
            + " leave the Custom Mount Point empty to use the default location.",
          ["%1$@", "%2$@"]
        ),
        ("Could not eject: %@", ["%@"]),
      ] {
        let value = bundle.localizedString(forKey: key, value: "<missing>", table: nil)
        XCTAssertNotEqual(value, "<missing>", "\(language): \(key)")
        for placeholder in placeholders {
          XCTAssertTrue(value.contains(placeholder), "\(language): \(placeholder) in \(key)")
        }
      }
    }
  }
}
