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
