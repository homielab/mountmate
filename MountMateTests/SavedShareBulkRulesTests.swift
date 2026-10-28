//  Created by homielab.com

import XCTest

@testable import MountMate

/// "Mount All Saved Shares" / "Unmount All Saved Shares": which shares each
/// acts on, and how failures are worded for the alert and Shortcuts.
final class SavedShareBulkRulesTests: XCTestCase {
  private func share(_ name: String) -> NetworkShare {
    NetworkShare(name: name, server: "nas.local", sharePath: name.lowercased(), username: "")
  }

  func testMountTakesUnmountedSharesAndUnmountTakesMountedOnesInSavedOrder() {
    let media = share("Media")
    let backup = share("Backup")
    let photos = share("Photos")
    let candidates = SavedShareBulkRules.candidates(
      shares: [media, backup, photos], mountedIDs: [backup.id])
    XCTAssertEqual(candidates.mount.map(\.name), ["Media", "Photos"])
    XCTAssertEqual(candidates.unmount.map(\.name), ["Backup"])
  }

  func testNoCandidatesWithoutSavedShares() {
    let candidates = SavedShareBulkRules.candidates(shares: [], mountedIDs: [UUID()])
    XCTAssertEqual(candidates, .init(mount: [], unmount: []))
  }

  func testMountedIDsOfManualSharesAreIgnored() {
    let media = share("Media")
    let candidates = SavedShareBulkRules.candidates(shares: [media], mountedIDs: [UUID()])
    XCTAssertEqual(candidates.mount, [media])
    XCTAssertEqual(candidates.unmount, [])
  }

  func testAllMountedLeavesNothingToMount() {
    let media = share("Media")
    let backup = share("Backup")
    let candidates = SavedShareBulkRules.candidates(
      shares: [media, backup], mountedIDs: [media.id, backup.id])
    XCTAssertEqual(candidates.mount, [])
    XCTAssertEqual(candidates.unmount, [media, backup])
  }

  func testMountFailureReasonsNameEachShare() {
    let reasons = SavedShareBulkRules.mountFailureReasons(
      [.init(name: "Media", reason: "Host down"), .init(name: "Backup", reason: nil)],
      localize: { $0 })
    XCTAssertEqual(reasons, ["Could not mount “Media”: Host down", "Could not mount “Backup”."])
  }

  func testBulkShareFailureListsNamesThenReasons() {
    XCTAssertEqual(
      IntentMessages.bulkShareFailure(
        names: ["Media", "Backup"], mount: false,
        reasons: ["“Media” is busy: a file on it is still in use.", ""], localize: { $0 }),
      "Could not unmount: Media, Backup\n\n“Media” is busy: a file on it is still in use.")
    XCTAssertEqual(
      IntentMessages.bulkShareFailure(names: ["Media"], mount: true, reasons: [], localize: { $0 }),
      "Could not mount: Media")
  }

  func testSuccessMessagesAreTranslated() throws {
    let english = try localizer("en")
    for language in ["fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"] {
      let localize = try localizer(language)
      XCTAssertNotEqual(
        IntentMessages.sharesMounted(localize: localize),
        IntentMessages.sharesMounted(localize: english), language)
      XCTAssertNotEqual(
        IntentMessages.sharesUnmounted(localize: localize),
        IntentMessages.sharesUnmounted(localize: english), language)
    }
  }

  private func localizer(_ language: String) throws -> IntentMessages.Localize {
    let path = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"))
    let bundle = try XCTUnwrap(Bundle(path: path))
    return { bundle.localizedString(forKey: $0, value: nil, table: nil) }
  }
}
