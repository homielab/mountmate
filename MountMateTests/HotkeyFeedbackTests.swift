import XCTest

@testable import MountMate

final class HotkeyFeedbackTests: XCTestCase {
  private func bundle(_ language: String) throws -> Bundle {
    let path = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"),
      "missing \(language).lproj")
    return try XCTUnwrap(Bundle(path: path))
  }

  private func message(
    _ action: HotkeyAction, _ succeeded: Int, _ failed: Int, language: String = "en"
  ) throws -> String {
    HotkeyFeedback.message(
      action: action, succeeded: succeeded, failed: failed, bundle: try bundle(language),
      locale: Locale(identifier: language))
  }

  func testEnglishMessagesForNothingOneManyAndFailures() throws {
    let cases: [(HotkeyAction, Int, Int, String)] = [
      (.unmountAll, 0, 0, "Nothing to unmount"),
      (.unmountAll, 1, 0, "Unmounted 1 volume"),
      (.unmountAll, 3, 0, "Unmounted 3 volumes"),
      (.unmountAll, 2, 1, "Unmounted 2 volumes, 1 failed"),
      (.unmountAll, 0, 2, "Could not unmount 2 volumes"),
      (.mountAll, 0, 0, "Nothing to mount"),
      (.mountAll, 1, 0, "Mounted 1 volume"),
      (.mountAll, 4, 0, "Mounted 4 volumes"),
      (.mountAll, 1, 2, "Mounted 1 volume, 2 failed"),
      (.mountAll, 0, 1, "Could not mount 1 volume"),
      (.ejectAll, 0, 0, "Nothing to eject"),
      (.ejectAll, 1, 0, "Ejected 1 disk"),
      (.ejectAll, 2, 0, "Ejected 2 disks"),
      (.ejectAll, 1, 1, "Ejected 1 disk, 1 failed"),
      (.ejectAll, 0, 3, "Could not eject 3 disks"),
      (.mountAllShares, 0, 0, "No network shares to mount"),
      (.mountAllShares, 1, 0, "Mounted 1 network share"),
      (.mountAllShares, 2, 1, "Mounted 2 network shares, 1 failed"),
      (.mountAllShares, 0, 2, "Could not mount 2 network shares"),
      (.unmountAllShares, 0, 0, "No network shares to unmount"),
      (.unmountAllShares, 3, 0, "Unmounted 3 network shares"),
      (.unmountAllShares, 1, 1, "Unmounted 1 network share, 1 failed"),
      (.unmountAllShares, 0, 1, "Could not unmount 1 network share"),
    ]
    for (action, succeeded, failed, expected) in cases {
      XCTAssertEqual(
        try message(action, succeeded, failed), expected, "\(action) \(succeeded)/\(failed)")
    }
  }

  func testRussianUsesItsPluralForms() throws {
    XCTAssertEqual(try message(.unmountAll, 1, 0, language: "ru"), "Отмонтирован 1 том")
    XCTAssertEqual(try message(.unmountAll, 2, 0, language: "ru"), "Отмонтировано 2 тома")
    XCTAssertEqual(try message(.unmountAll, 5, 0, language: "ru"), "Отмонтировано 5 томов")
    XCTAssertEqual(try message(.ejectAll, 21, 0, language: "ru"), "Извлечён 21 диск")
    XCTAssertEqual(
      try message(.mountAllShares, 5, 0, language: "ru"), "Смонтировано 5 сетевых папок")
  }

  func testEveryLanguageTranslatesEveryCase() throws {
    let english = try bundle("en")
    for language in ["fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"] {
      for action in HotkeyAction.allCases {
        for (succeeded, failed) in [(0, 0), (1, 0), (3, 0), (2, 1), (0, 2)] {
          let text = try message(action, succeeded, failed, language: language)
          let englishText = HotkeyFeedback.message(
            action: action, succeeded: succeeded, failed: failed, bundle: english,
            locale: Locale(identifier: "en"))
          XCTAssertNotEqual(text, englishText, "\(language) \(action) \(succeeded)/\(failed)")
          XCTAssertFalse(text.contains("hotkey."), "\(language) misses a key: \(text)")
        }
      }
    }
  }

  func testIconTellsSuccessNothingAndFailureApart() {
    XCTAssertEqual(HotkeyFeedback.systemImage(succeeded: 2, failed: 0), "checkmark.circle.fill")
    XCTAssertEqual(HotkeyFeedback.systemImage(succeeded: 0, failed: 0), "info.circle.fill")
    XCTAssertEqual(
      HotkeyFeedback.systemImage(succeeded: 1, failed: 1), "exclamationmark.triangle.fill")
    XCTAssertEqual(
      HotkeyFeedback.systemImage(succeeded: 0, failed: 1), "exclamationmark.triangle.fill")
  }

  func testTintIsGreenOnlyWhenEverythingWorked() {
    XCTAssertEqual(HotkeyFeedback.tint(succeeded: 2, failed: 0), .success)
    XCTAssertEqual(HotkeyFeedback.tint(succeeded: 0, failed: 0), .neutral)
    XCTAssertEqual(HotkeyFeedback.tint(succeeded: 1, failed: 1), .warning)
    XCTAssertEqual(HotkeyFeedback.tint(succeeded: 0, failed: 1), .warning)
  }

  func testASecondPressWhileTheActionRunsIsSkipped() {
    XCTAssertTrue(
      HotkeyFeedback.skipsPress(of: .unmountAll, unmountingAll: true, mountingAll: false))
    XCTAssertFalse(
      HotkeyFeedback.skipsPress(of: .unmountAll, unmountingAll: false, mountingAll: true))
    XCTAssertTrue(HotkeyFeedback.skipsPress(of: .mountAll, unmountingAll: false, mountingAll: true))
    XCTAssertFalse(HotkeyFeedback.skipsPress(of: .ejectAll, unmountingAll: true, mountingAll: true))
  }
}
