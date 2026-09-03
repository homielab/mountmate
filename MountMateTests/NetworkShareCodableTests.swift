//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkShareCodableTests: XCTestCase {
  func testEncodeDecodeRoundTripPreservesNewFields() throws {
    let share = NetworkShare(
      name: "Media", server: "nas.local", sharePath: "media", username: "me",
      mountAtLogin: true, keepMounted: false, shareProtocol: .nfs,
      customMountPoint: "~/mnt/media")

    let data = try JSONEncoder().encode([share])
    let decoded = try JSONDecoder().decode([NetworkShare].self, from: data)

    XCTAssertEqual(decoded.count, 1)
    XCTAssertEqual(decoded[0].shareProtocol, .nfs)
    XCTAssertFalse(decoded[0].keepMounted)
    XCTAssertEqual(decoded[0].customMountPoint, "~/mnt/media")
  }

  func testDecodingLegacyShareWithoutNewFieldsFallsBack() throws {
    // Payload shape saved by MountMate <= 5.17: no keepMounted/shareProtocol.
    struct LegacyShare: Codable {
      let id: UUID
      let name: String
      let server: String
      let sharePath: String
      let username: String
      let mountAtLogin: Bool
      let customMountPoint: String?
    }

    let legacy = LegacyShare(
      id: UUID(), name: "Backup", server: "server.local", sharePath: "backup",
      username: "user", mountAtLogin: true, customMountPoint: nil)
    let data = try JSONEncoder().encode([legacy])

    let decoded = try JSONDecoder().decode([NetworkShare].self, from: data)

    XCTAssertEqual(decoded.count, 1)
    XCTAssertEqual(decoded[0].shareProtocol, .smb)
    // Shares that mounted at login were the historical auto-mount set, so
    // keep-alive follows mountAtLogin for legacy entries.
    XCTAssertTrue(decoded[0].keepMounted)

    let guest = LegacyShare(
      id: UUID(), name: "Public", server: "server.local", sharePath: "public",
      username: "", mountAtLogin: false, customMountPoint: nil)
    let guestData = try JSONEncoder().encode([guest])
    let guestDecoded = try JSONDecoder().decode([NetworkShare].self, from: guestData)
    XCTAssertFalse(guestDecoded[0].keepMounted)
  }

  func testNFSExportPathRoundTripsThroughURL() throws {
    let share = NetworkShare(
      name: "Exports", server: "192.168.1.10", sharePath: "exports/public",
      username: "", mountAtLogin: false, shareProtocol: .nfs)

    let url = try XCTUnwrap(NetworkMountManager.shared.connectionURL(for: share, password: ""))
    XCTAssertEqual(url.absoluteString, "nfs://192.168.1.10/exports/public")
  }

  func testAFPURLIncludesCredentials() throws {
    let share = NetworkShare(
      name: "Time Capsule", server: "tc.local", sharePath: "Data", username: "admin",
      mountAtLogin: false, shareProtocol: .afp)

    let url = try XCTUnwrap(NetworkMountManager.shared.connectionURL(for: share, password: "s3cret"))
    XCTAssertTrue(url.absoluteString.hasPrefix("afp://admin:s3cret@tc.local/Data"))
  }
}
