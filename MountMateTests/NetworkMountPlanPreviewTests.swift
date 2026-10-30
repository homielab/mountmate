//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkMountPlanPreviewTests: XCTestCase {
  private func preview(
    _ server: String, _ path: String, _ proto: ShareProtocol = .smb, user: String = ""
  ) -> String {
    NetworkMountPlan.connectionPreview(
      for: NetworkShare(
        name: "x", server: server, sharePath: path, username: user, shareProtocol: proto))
  }

  func testSMBPlain() {
    XCTAssertEqual(preview("nas", "Public"), "smb://nas/Public")
  }

  func testSMBUserAndPortInServerField() {
    XCTAssertEqual(preview("admin@nas:445", "Public"), "smb://nas:445/Public")
  }

  func testSMBIPv6WithPort() {
    XCTAssertEqual(preview("[fd00::2]:8445", "Public"), "smb://[fd00::2]:8445/Public")
    XCTAssertEqual(preview("fd00::2", "Public"), "smb://[fd00::2]/Public")
  }

  func testSMBDomainLoginGoesInURL() {
    XCTAssertEqual(preview("nas", "Public", user: "CORP\\bob"), "smb://CORP;bob@nas/Public")
  }

  func testPathWithSpacesIsEncodedAsSent() {
    XCTAssertEqual(preview("nas", "My Files"), "smb://nas/My%20Files")
  }

  func testAFP() {
    XCTAssertEqual(preview("mac", "Share", .afp), "afp://mac/Share")
  }

  func testNFSShowsMountTarget() {
    XCTAssertEqual(preview("nas", "exports/data", .nfs), "nas:/exports/data")
  }

  func testNFSWithPort() {
    XCTAssertEqual(preview("nas:2049", "exports/data", .nfs), "nas:/exports/data -o port=2049")
    XCTAssertEqual(
      preview("[fd00::2]:2049", "export", .nfs), "[fd00::2]:/export -o port=2049")
  }

  func testEmptyFieldsShowPlaceholders() {
    XCTAssertEqual(preview("", ""), "smb://server/share")
    XCTAssertEqual(preview("", "", .nfs), "server:/share")
  }

  private func listAddress(
    _ server: String, _ path: String, _ proto: ShareProtocol = .smb, user: String = ""
  ) -> String {
    NetworkMountPlan.listAddress(
      for: NetworkShare(
        name: "x", server: server, sharePath: path, username: user, shareProtocol: proto))
  }

  func testListAddressMatchesRealAddress() {
    XCTAssertEqual(listAddress("nas", "volume1/media", .nfs), "nas:/volume1/media")
    XCTAssertEqual(listAddress("fd00::2", "share"), "smb://[fd00::2]/share")
    XCTAssertEqual(listAddress("nas", "My Files"), "smb://nas/My%20Files")
    XCTAssertEqual(listAddress("nas", "Public", .afp), "afp://nas/Public")
  }

  func testListAddressShowsSavedUserWithoutPassword() {
    XCTAssertEqual(listAddress("nas", "Public", user: "bob"), "smb://bob@nas/Public")
    XCTAssertEqual(listAddress("nas", "Public", .afp, user: "bob"), "afp://bob@nas/Public")
    XCTAssertEqual(listAddress("nas", "Public", user: "CORP\\bob"), "smb://CORP;bob@nas/Public")
    XCTAssertEqual(listAddress("nas", "volume1", .nfs, user: "bob"), "nas:/volume1")
    XCTAssertEqual(listAddress("admin:pw@nas", "Public"), "smb://nas/Public")
  }
}
