//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkShareValidationTests: XCTestCase {
  private func share(name: String, server: String = "nas.local", path: String = "media")
    -> NetworkShare
  {
    NetworkShare(name: name, server: server, sharePath: path, username: "")
  }

  private let mountUnderVolumes: (NetworkShare) -> String = { "/Volumes/\($0.name)" }

  func testAcceptsADistinctShare() {
    XCTAssertNil(
      NetworkShareValidation.error(
        candidate: share(name: "Media"), original: nil,
        otherShares: [share(name: "Docs", server: "other.local")],
        mountPoint: mountUnderVolumes))
  }

  func testAllowsAnEditThatKeepsADuplicateEndpoint() {
    let saved = share(name: "Media")
    let candidate = share(name: "Copy")
    XCTAssertNotNil(
      NetworkShareValidation.error(
        candidate: candidate, original: nil, otherShares: [saved], mountPoint: mountUnderVolumes))
    XCTAssertNil(
      NetworkShareValidation.error(
        candidate: candidate, original: candidate, otherShares: [saved],
        mountPoint: mountUnderVolumes))
  }

  func testRejectsAnEditThatMovesToAnotherSharesEndpoint() {
    let media = share(name: "Media", path: "Media")
    let docs = share(name: "Docs", path: "Docs")
    var edited = docs
    edited.sharePath = "Media"
    XCTAssertNotNil(
      NetworkShareValidation.error(
        candidate: edited, original: docs, otherShares: [media], mountPoint: mountUnderVolumes))
  }

  func testAcceptsAnEditThatMovesToAFreeEndpoint() {
    let media = share(name: "Media", path: "Media")
    let docs = share(name: "Docs", path: "Docs")
    var edited = docs
    edited.sharePath = "Photos"
    XCTAssertNil(
      NetworkShareValidation.error(
        candidate: edited, original: docs, otherShares: [media], mountPoint: mountUnderVolumes))
  }

  func testRejectsASharedMountPoint() {
    let saved = share(name: "Media", server: "a.local")
    let candidate = share(name: "Media", server: "b.local")
    XCTAssertNotNil(
      NetworkShareValidation.error(
        candidate: candidate, original: nil, otherShares: [saved], mountPoint: mountUnderVolumes))
  }

  // MARK: - Mount point path rules

  private let resolveLikeTheApp: (NetworkShare) -> String = {
    NetworkMountTable.configuredMountPoint(for: $0, homeDirectory: "/Users/test")
  }

  private func error(customMountPoint: String?, name: String = "Media") -> String? {
    var candidate = share(name: name)
    candidate.customMountPoint = customMountPoint
    return NetworkShareValidation.error(
      candidate: candidate, original: nil, otherShares: [], mountPoint: resolveLikeTheApp)
  }

  private var rootError: String {
    NSLocalizedString("Custom Mount Point Cannot Be Root", comment: "")
  }

  private var controlCharacterError: String {
    NSLocalizedString("Custom Mount Point Control Characters", comment: "")
  }

  func testRejectsTheRootFolderAsMountPoint() {
    XCTAssertEqual(error(customMountPoint: "/"), rootError)
    XCTAssertEqual(error(customMountPoint: "//"), rootError)
    XCTAssertEqual(error(customMountPoint: "/Volumes/.."), rootError)
    XCTAssertEqual(error(customMountPoint: "/./"), rootError)
  }

  func testResolvesTildeAndDotSegmentsBeforeChecking() {
    // `~/x/..` is the home folder: allowed.
    XCTAssertNil(error(customMountPoint: "~/x/.."))
    // Climbing out of the home folder up to `/` is refused.
    let homeDepth =
      FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
      .pathComponents.count - 1
    let upToRoot = "~" + String(repeating: "/..", count: homeDepth)
    XCTAssertEqual(error(customMountPoint: upToRoot), rootError)
    // A relative path is under the home folder: `../..` from /Users/test is `/`.
    XCTAssertEqual(error(customMountPoint: "../.."), rootError)
  }

  func testRejectsControlCharactersInTheMountPoint() {
    XCTAssertEqual(error(customMountPoint: "/Volumes/Me\ndia"), controlCharacterError)
    XCTAssertEqual(error(customMountPoint: "~/mountmate/a\u{7}b"), controlCharacterError)
  }

  func testRejectsControlCharactersInTheNameUsedAsDefaultMountPoint() {
    XCTAssertEqual(error(customMountPoint: nil, name: "Me\ndia"), controlCharacterError)
  }

  func testAcceptsValidMountPoints() {
    XCTAssertNil(error(customMountPoint: nil))
    XCTAssertNil(error(customMountPoint: "~/mountmate/Media"))
    XCTAssertNil(error(customMountPoint: "/Volumes/Media Share"))
    XCTAssertNil(error(customMountPoint: "/Users/test/../test/Shares/Media"))
    XCTAssertNil(error(customMountPoint: "Shares/Média"))
  }

  func testPathRulesAreSharedWithVolumeMountPoints() {
    XCTAssertEqual(CustomMountPointValidator.pathRuleError("/"), rootError)
    XCTAssertEqual(
      CustomMountPointValidator.validationError(for: "//", mountedVolumeName: { _ in nil }),
      rootError)
    XCTAssertNil(CustomMountPointValidator.pathRuleError("/Volumes/Data"))
  }
}
