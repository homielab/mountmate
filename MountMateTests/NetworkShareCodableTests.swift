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

    let url = try XCTUnwrap(NetworkMountManager.shared.connectionURL(for: share))
    XCTAssertEqual(url.absoluteString, "nfs://192.168.1.10/exports/public")
  }

  func testConnectionURLNeverEmbedsCredentials() throws {
    // Credentials go to NetFS separately; a URL must never carry them (they
    // used to end up in mount_smbfs/mount_afp arguments, visible via `ps`).
    for shareProtocol in [ShareProtocol.smb, .afp] {
      let share = NetworkShare(
        name: "Time Capsule", server: "tc.local", sharePath: "Data", username: "admin",
        mountAtLogin: false, shareProtocol: shareProtocol)

      let url = try XCTUnwrap(NetworkMountManager.shared.connectionURL(for: share))
      XCTAssertEqual(url.absoluteString, "\(shareProtocol.urlScheme)://tc.local/Data")
      XCTAssertNil(url.user)
      XCTAssertNil(url.password)
    }
  }

  func testDomainUserGoesIntoURLWithoutPassword() throws {
    let share = NetworkShare(
      name: "Projects", server: "fs.corp.example", sharePath: "projects", username: "")
    let url = try XCTUnwrap(
      NetworkMountManager.shared.connectionURL(for: share, user: "CORP;alice"))
    XCTAssertEqual(url.user, "CORP;alice")
    XCTAssertNil(url.password)
    XCTAssertEqual(url.host, "fs.corp.example")
    XCTAssertEqual(url.path, "/projects")
  }

  func testCleanedServerInputStripsWhitespaceAndScheme() {
    XCTAssertEqual(NetworkShare.cleanedServerInput("  nas.local \n"), "nas.local")
    XCTAssertEqual(NetworkShare.cleanedServerInput("smb://nas.local/"), "nas.local")
    XCTAssertEqual(NetworkShare.cleanedServerInput("AFP://tc.local"), "tc.local")
    XCTAssertEqual(NetworkShare.cleanedServerInput("nfs://10.0.0.2"), "10.0.0.2")
  }

  func testDisplayNameValidation() {
    XCTAssertNil(NetworkShare.displayNameValidationError("Media"))
    XCTAssertNil(NetworkShare.displayNameValidationError("My Share (2)"))
    XCTAssertNotNil(NetworkShare.displayNameValidationError("a/b"))
    XCTAssertNotNil(NetworkShare.displayNameValidationError("../Desktop"))
    XCTAssertNotNil(NetworkShare.displayNameValidationError("."))
    XCTAssertNotNil(NetworkShare.displayNameValidationError(".."))
  }

  func testSameEndpointIgnoresCaseSlashesAndScheme() {
    let a = NetworkShare(name: "A", server: "NAS.local", sharePath: "/Media/", username: "")
    let b = NetworkShare(name: "B", server: "nas.local", sharePath: "media", username: "me")
    let c = NetworkShare(name: "C", server: "nas2.local", sharePath: "media", username: "")
    let d = NetworkShare(
      name: "D", server: "nas.local", sharePath: "media", username: "", shareProtocol: .afp)
    XCTAssertTrue(a.hasSameEndpoint(as: b))
    XCTAssertFalse(a.hasSameEndpoint(as: c))
    XCTAssertFalse(a.hasSameEndpoint(as: d))
  }
}
