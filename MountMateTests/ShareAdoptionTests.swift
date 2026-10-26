//  Created by homielab.com

import XCTest

@testable import MountMate

final class ShareAdoptionTests: XCTestCase {
  private let share = NetworkShare(name: "NAS", server: "nas", sharePath: "public", username: "")

  private func ipMount() throws -> MountedNetworkShare {
    try XCTUnwrap(
      MountedNetworkShare(
        source: "//192.168.1.5/public", mountPoint: "/Volumes/public", fileSystemType: "smbfs"))
  }

  func testAdoptedMountCountsAsTheSavedShare() throws {
    let adoption = ShareAdoption()
    let mount = try ipMount()

    XCTAssertTrue(adoption.parse([mount], savedShares: [share]).mountedShareIDs.isEmpty)

    adoption.adopt("/Volumes/public", for: share)
    let parsed = adoption.parse([mount], savedShares: [share])
    XCTAssertEqual(parsed.mountedShareIDs, [share.id])
    XCTAssertEqual(parsed.mountPoints[share.id], "/Volumes/public")
    XCTAssertTrue(parsed.manualShares.isEmpty)
  }

  func testForgetEndsTheAdoption() throws {
    let adoption = ShareAdoption()
    let mount = try ipMount()
    adoption.adopt("/Volumes/public", for: share)
    XCTAssertNotNil(adoption.adoption(forShareID: share.id))

    adoption.forget(shareID: share.id)

    XCTAssertNil(adoption.adoption(forShareID: share.id))
    let parsed = adoption.parse([mount], savedShares: [share])
    XCTAssertTrue(parsed.mountedShareIDs.isEmpty)
    XCTAssertEqual(parsed.manualShares.count, 1)
  }

  func testParseDropsAdoptionWhenMountDisappears() throws {
    let adoption = ShareAdoption()
    adoption.adopt("/Volumes/public", for: share)

    _ = adoption.parse([], savedShares: [share])

    XCTAssertNil(adoption.adoption(forShareID: share.id))
  }
}
