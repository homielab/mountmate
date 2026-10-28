//  Created by homielab.com

import XCTest

@testable import MountMate

final class MountFailureTests: XCTestCase {
  private let languages = ["en", "fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"]

  private func localizer(_ language: String) throws -> MountFailure.Localize {
    let path = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"))
    let bundle = try XCTUnwrap(Bundle(path: path))
    return { key in
      let value = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
      return value == "MISSING" ? "MISSING: \(key)" : value
    }
  }

  func testEnglishMessages() throws {
    let english = try localizer("en")
    XCTAssertEqual(
      MountFailure.busy(localize: english).localizedDescription,
      "Another operation on this volume is running.")
    XCTAssertEqual(
      MountFailure.timedOut(localize: english).localizedDescription,
      "Timed out waiting for the mount to finish.")
    XCTAssertEqual(
      DiskOperationError.ejectInProgress(localize: english).localizedDescription,
      "This disk is already being ejected.")
  }

  func testMessagesAreTranslatedInEveryLanguage() throws {
    let english = try localizer("en")
    for language in languages where language != "en" {
      let localize = try localizer(language)
      let pairs: [(translated: String, original: String)] = [
        (
          MountFailure.busy(localize: localize).message,
          MountFailure.busy(localize: english).message
        ),
        (
          MountFailure.timedOut(localize: localize).message,
          MountFailure.timedOut(localize: english).message
        ),
        (
          DiskOperationError.ejectInProgress(localize: localize).message,
          DiskOperationError.ejectInProgress(localize: english).message
        ),
      ]
      for pair in pairs {
        XCTAssertFalse(pair.translated.hasPrefix("MISSING"), "\(language): \(pair.translated)")
        XCTAssertNotEqual(pair.translated, pair.original, language)
      }
    }
  }

  func testShortcutsFailureCarriesTheTranslatedReason() throws {
    let localize = try localizer("vi")
    let reason = MountFailure.busy(localize: localize).localizedDescription
    let message = IntentMessages.shareFailure(name: "NAS", reason: reason, localize: localize)
    XCTAssertTrue(message.contains("NAS"))
    XCTAssertTrue(message.contains(reason))
    XCTAssertFalse(message.contains("Another operation"))
  }
}
