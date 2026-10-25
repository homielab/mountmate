import XCTest

@testable import MountMate

final class PluralizedStringTests: XCTestCase {
  private func bundle(_ language: String) throws -> Bundle {
    let path = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"),
      "missing \(language).lproj")
    return try XCTUnwrap(Bundle(path: path))
  }

  private func format(_ key: String, _ language: String, _ arguments: CVarArg...) throws -> String {
    let template = try bundle(language).localizedString(forKey: key, value: key, table: nil)
    return String(format: template, locale: Locale(identifier: language), arguments: arguments)
  }

  func testRussianBlockedDiskCountUsesAllFourForms() throws {
    let expected = [
      1: "Блокируется при запуске: 1 диск.",
      2: "Блокируется при запуске: 2 диска.",
      5: "Блокируется при запуске: 5 дисков.",
      11: "Блокируется при запуске: 11 дисков.",
      21: "Блокируется при запуске: 21 диск.",
      22: "Блокируется при запуске: 22 диска.",
    ]
    for (count, text) in expected {
      XCTAssertEqual(try format("startup.blocked.count", "ru", count), text)
    }
  }

  func testMenuBarMountedCountIsPluralAwareAndAccessibilityKeysExist() throws {
    XCTAssertEqual(try format("menubar.mounted.count", "en", 1), "1 volume mounted")
    XCTAssertEqual(try format("menubar.mounted.count", "en", 3), "3 volumes mounted")
    XCTAssertEqual(try format("menubar.mounted.count", "ru", 5), "Подключено 5 томов")
    for language in ["en", "fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"] {
      for key in ["Accessibility Busy", "Accessibility Error"] {
        XCTAssertNotEqual(
          try bundle(language).localizedString(forKey: key, value: key, table: nil), key,
          "\(language) misses \(key)")
      }
    }
  }

  func testUkrainianRetryMinutes() throws {
    XCTAssertEqual(try format("retry.minutes", "uk", 1), "Кожну 1 хвилину")
    XCTAssertEqual(try format("retry.minutes", "uk", 2), "Кожні 2 хвилини")
    XCTAssertEqual(try format("retry.minutes", "uk", 5), "Кожні 5 хвилин")
    XCTAssertEqual(try format("retry.minutes", "uk", 21), "Кожну 21 хвилину")
  }

  func testRussianIdleMessageKeepsNameAndPluralizesMinutes() throws {
    XCTAssertEqual(
      try format("idle.unmounted", "ru", "Backup", 1),
      "«Backup» отключён после 1 минуты без использования.")
    XCTAssertEqual(
      try format("idle.unmounted", "ru", "Backup", 5),
      "«Backup» отключён после 5 минут без использования.")
  }

  func testEnglishSingularAndPlural() throws {
    XCTAssertEqual(try format("startup.blocked.count", "en", 1), "Blocked at startup: 1 disk.")
    XCTAssertEqual(try format("startup.blocked.count", "en", 2), "Blocked at startup: 2 disks.")
    XCTAssertEqual(try format("retry.minutes", "en", 1), "Every 1 minute")
  }

  func testLanguagesWithoutPluralFormsUseOneSentence() throws {
    for language in ["vi", "zh-Hans", "zh-Hant"] {
      let one = try format("startup.blocked.count", language, 1)
      let many = try format("startup.blocked.count", language, 5)
      XCTAssertTrue(one.contains("1"))
      XCTAssertTrue(many.contains("5"))
    }
  }

  func testEveryLanguageDefinesEveryPluralKeyAndAFormsPerRules() throws {
    let keys = [
      "shares.imported", "startup.blocked.added", "startup.blocked.count", "retry.seconds",
      "retry.minutes", "idle.unmounted",
    ]
    for language in ["en", "fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"] {
      for key in keys {
        let text = try format(key, language, "x", 3)
        XCTAssertNotEqual(text, key, "\(language) lacks \(key)")
        XCTAssertFalse(text.contains("%"), "\(language) \(key): \(text)")
      }
    }
  }

  func testFailureSentencesExistInEveryLanguage() throws {
    let keys = [
      "Failed to mount “%@” because it is currently in use by “%@”.",
      "Failed to unmount “%@” because it is currently in use by another application.",
      "Failed to eject “%@” because it is currently in use by “%@”.",
      "An unknown error occurred while trying to unmount “%@”.",
    ]
    for language in ["en", "fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"] {
      for key in keys {
        XCTAssertNotEqual(
          try bundle(language).localizedString(forKey: key, value: "MISSING", table: nil),
          "MISSING", "\(language): \(key)")
      }
    }
  }
}
