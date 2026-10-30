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

  // MARK: - Server address and port

  func testSharesOnDifferentPortsOfOneHostAreDifferentShares() {
    let standard = share(name: "Data", server: "nas:445", path: "data")
    let container = share(name: "Data 2", server: "nas:4450", path: "data")
    XCTAssertFalse(standard.hasSameEndpoint(as: container))
    XCTAssertNil(
      NetworkShareValidation.error(
        candidate: container, original: nil, otherShares: [standard],
        mountPoint: mountUnderVolumes))
    // The default port written out or left off is the same server.
    XCTAssertTrue(share(name: "A", server: "nas", path: "data").hasSameEndpoint(as: standard))
    XCTAssertNotNil(
      NetworkShareValidation.error(
        candidate: share(name: "Copy", server: "nas", path: "data"), original: nil,
        otherShares: [standard], mountPoint: mountUnderVolumes))
  }

  func testRejectsInvalidServerAddresses() {
    let hostError = NetworkShare.serverValidationError("my nas")
    let portError = NetworkShare.serverValidationError("nas:99999")
    XCTAssertNotNil(hostError)
    XCTAssertNotNil(portError)
    XCTAssertNotEqual(hostError, portError)

    for server in ["nas:abc", "nas:99999", "nas:0", "nas:", "nas:+445", "[fe80::1]:x"] {
      XCTAssertEqual(NetworkShare.serverAddressProblem(server), .invalidPort, server)
    }
    for server in [
      "my nas", "nas/share", "nas?x", "nas#1", ":445", "[nas]", "[fe80::1", "[fe80::1]x",
      "fe80::zz", "fe80::1%", "fe80::1%en 0", "...",
    ] {
      XCTAssertEqual(NetworkShare.serverAddressProblem(server), .invalidHost, server)
    }
    XCTAssertEqual(
      NetworkShareValidation.error(
        candidate: share(name: "Media", server: "nas:abc"), original: nil, otherShares: [],
        mountPoint: mountUnderVolumes),
      portError)
  }

  func testAcceptsValidServerAddresses() {
    for server in [
      "nas", "nas.local", "NAS-01.example.com", "my_nas", "192.168.1.10", "192.168.1.10:445",
      "nas:65535", "nas:1", "fe80::1", "[fe80::1]", "[fe80::1]:445", "fe80::1%en0",
      "[fe80::1%25en0]:445", "admin@nas:445", "bücher.example",
    ] {
      XCTAssertNil(NetworkShare.serverAddressProblem(server), server)
    }
  }

  func testInvalidServerSavedBeforeTheCheckCanStillBeEdited() {
    let old = share(name: "Media", server: "nas:abc")
    var renamed = old
    renamed.name = "Renamed"
    XCTAssertNil(
      NetworkShareValidation.error(
        candidate: renamed, original: old, otherShares: [], mountPoint: mountUnderVolumes))
  }
}
