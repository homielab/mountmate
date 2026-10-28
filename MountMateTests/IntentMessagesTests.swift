//  Created by homielab.com

import XCTest

@testable import MountMate

final class IntentMessagesTests: XCTestCase {
  private let languages = ["en", "fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"]

  private func localizer(_ language: String) throws -> IntentMessages.Localize {
    let path = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"))
    let bundle = try XCTUnwrap(Bundle(path: path))
    return { bundle.localizedString(forKey: $0, value: nil, table: nil) }
  }

  func testVolumeFailureListsNames() {
    XCTAssertEqual(
      IntentMessages.volumeFailure(names: ["A", "B"], mount: true, localize: { $0 }),
      "Could not mount: A, B")
    XCTAssertEqual(
      IntentMessages.volumeFailure(names: ["A"], mount: false, localize: { $0 }),
      "Could not unmount: A")
  }

  func testEjectFailureListsNamesAndIsTranslated() throws {
    XCTAssertEqual(
      IntentMessages.ejectFailure(names: ["A", "B"], localize: { $0 }), "Could not eject: A, B")
    XCTAssertEqual(
      IntentMessages.ejectFailure(
        names: ["A", "B"], reasons: ["“A”: busy", "“B”: timed out"], localize: { $0 }),
      "Could not eject: A, B\n“A”: busy\n“B”: timed out")
    let english = try localizer("en")
    for language in languages where language != "en" {
      let localize = try localizer(language)
      XCTAssertNotEqual(
        IntentMessages.disksEjected(localize: localize),
        IntentMessages.disksEjected(localize: english), language)
      XCTAssertTrue(
        IntentMessages.ejectFailure(names: ["NAS"], localize: localize).contains("NAS"), language)
    }
  }

  func testShareFailureWithAndWithoutReason() {
    XCTAssertEqual(
      IntentMessages.shareFailure(name: "NAS", reason: "Host down", localize: { $0 }),
      "Could not mount “NAS”: Host down")
    XCTAssertEqual(
      IntentMessages.shareFailure(name: "NAS", reason: "", localize: { $0 }),
      "Could not mount “NAS”.")
    XCTAssertEqual(
      IntentMessages.shareFailure(name: "NAS", reason: nil, localize: { $0 }),
      "Could not mount “NAS”.")
  }

  func testEveryLanguageTranslatesAndKeepsTheName() throws {
    for language in languages {
      let localize = try localizer(language)
      let english = try localizer("en")
      for text in [
        IntentMessages.volumesMounted(localize: localize),
        IntentMessages.volumesUnmounted(localize: localize),
        IntentMessages.shareNotFound(localize: localize),
      ] {
        XCTAssertFalse(text.isEmpty, language)
      }
      if language != "en" {
        XCTAssertNotEqual(
          IntentMessages.volumesMounted(localize: localize),
          IntentMessages.volumesMounted(localize: english), language)
      }
      XCTAssertTrue(
        IntentMessages.shareMounted(name: "NAS", localize: localize).contains("NAS"), language)
      let failure = IntentMessages.shareFailure(name: "NAS", reason: "boom", localize: localize)
      XCTAssertTrue(failure.contains("NAS") && failure.contains("boom"), language)
    }
  }

  func testEntityKeepsShareIdentity() {
    let share = NetworkShare(
      id: UUID(), name: "NAS", server: "nas.local", sharePath: "media", username: "me",
      mountAtLogin: false, keepMounted: false, shareProtocol: .smb, customMountPoint: nil)
    let entity = NetworkShareEntity(share: share)
    XCTAssertEqual(entity.id, share.id)
    XCTAssertEqual(entity.name, "NAS")
  }
}
