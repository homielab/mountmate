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

  func testRejectsADuplicateEndpointOnlyForNewShares() {
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

  func testRejectsASharedMountPoint() {
    let saved = share(name: "Media", server: "a.local")
    let candidate = share(name: "Media", server: "b.local")
    XCTAssertNotNil(
      NetworkShareValidation.error(
        candidate: candidate, original: nil, otherShares: [saved], mountPoint: mountUnderVolumes))
  }
}
