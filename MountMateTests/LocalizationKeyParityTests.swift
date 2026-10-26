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

  func testAllLanguagesHaveTheSamePluralKeys() throws {
    let english = try keys("en", table: "Localizable", type: "stringsdict")
    for language in languages.dropFirst() {
      XCTAssertEqual(
        try keys(language, table: "Localizable", type: "stringsdict"), english, language)
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
