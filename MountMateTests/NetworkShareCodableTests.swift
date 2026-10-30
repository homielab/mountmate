//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkShareCodableTests: XCTestCase {
  func testEncodeDecodeRoundTripPreservesNewFields() throws {
    let share = NetworkShare(
      name: "Media", server: "nas.local", sharePath: "media", username: "me",
      mountAtLogin: true, keepMounted: false, shareProtocol: .nfs,
      customMountPoint: "~/mnt/media", readOnly: true)

    let data = try JSONEncoder().encode([share])
    let decoded = try JSONDecoder().decode([NetworkShare].self, from: data)

    XCTAssertEqual(decoded.count, 1)
    XCTAssertEqual(decoded[0].shareProtocol, .nfs)
    XCTAssertFalse(decoded[0].keepMounted)
    XCTAssertEqual(decoded[0].customMountPoint, "~/mnt/media")
    XCTAssertTrue(decoded[0].readOnly)
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
    XCTAssertFalse(decoded[0].readOnly)

    let guest = LegacyShare(
      id: UUID(), name: "Public", server: "server.local", sharePath: "public",
      username: "", mountAtLogin: false, customMountPoint: nil)
    let guestData = try JSONEncoder().encode([guest])
    let guestDecoded = try JSONDecoder().decode([NetworkShare].self, from: guestData)
    XCTAssertFalse(guestDecoded[0].keepMounted)
  }

  func testDecodingAShareSavedBeforeReadOnlyMountsItWritable() throws {
    let json = #"""
      [{"id": "6F9A1C2E-3B4D-4E5F-8A9B-0C1D2E3F4A5B", "name": "Backup", "server": "nas",
        "sharePath": "backup", "username": "", "mountAtLogin": true, "keepMounted": true,
        "shareProtocol": "smb"}]
      """#
    let decoded = try JSONDecoder().decode([NetworkShare].self, from: Data(json.utf8))
    XCTAssertEqual(decoded.count, 1)
    XCTAssertFalse(decoded[0].readOnly)
  }

  func testNFSExportPathRoundTripsThroughURL() throws {
    let share = NetworkShare(
      name: "Exports", server: "192.168.1.10", sharePath: "exports/public",
      username: "", mountAtLogin: false, shareProtocol: .nfs)

    let url = try XCTUnwrap(NetworkMountPlan.connectionURL(for: share))
    XCTAssertEqual(url.absoluteString, "nfs://192.168.1.10/exports/public")
  }

  func testConnectionURLNeverEmbedsCredentials() throws {
    // Credentials go to NetFS separately; a URL must never carry them (they
    // used to end up in mount_smbfs/mount_afp arguments, visible via `ps`).
    for shareProtocol in [ShareProtocol.smb, .afp] {
      let share = NetworkShare(
        name: "Time Capsule", server: "tc.local", sharePath: "Data", username: "admin",
        mountAtLogin: false, shareProtocol: shareProtocol)

      let url = try XCTUnwrap(NetworkMountPlan.connectionURL(for: share))
      XCTAssertEqual(url.absoluteString, "\(shareProtocol.urlScheme)://tc.local/Data")
      XCTAssertNil(url.user)
      XCTAssertNil(url.password)
    }
  }

  func testDomainUserGoesIntoURLWithoutPassword() throws {
    let share = NetworkShare(
      name: "Projects", server: "fs.corp.example", sharePath: "projects", username: "")
    let url = try XCTUnwrap(
      NetworkMountPlan.connectionURL(for: share, user: "CORP;alice"))
    XCTAssertEqual(url.user, "CORP;alice")
    XCTAssertNil(url.password)
    XCTAssertEqual(url.host, "fs.corp.example")
    XCTAssertEqual(url.path, "/projects")
  }

  func testCleanedServerInputStripsWhitespaceAndScheme() {
    XCTAssertEqual(NetworkShare.cleanedServerInput("  nas.local \n").server, "nas.local")
    XCTAssertEqual(NetworkShare.cleanedServerInput("smb://nas.local/").server, "nas.local")
    XCTAssertEqual(NetworkShare.cleanedServerInput("smb://nas.local/").sharePath, "")
    XCTAssertEqual(NetworkShare.cleanedServerInput("AFP://tc.local").server, "tc.local")
    XCTAssertEqual(NetworkShare.cleanedServerInput("nfs://10.0.0.2").server, "10.0.0.2")
  }

  func testCleanedServerInputSplitsPastedURLIntoHostAndPath() {
    let sub = NetworkShare.cleanedServerInput("smb://nas.local/Public/sub")
    XCTAssertEqual(sub.server, "nas.local")
    XCTAssertEqual(sub.sharePath, "Public/sub")
    let noScheme = NetworkShare.cleanedServerInput(" nas/Public/ ")
    XCTAssertEqual(noScheme.server, "nas")
    XCTAssertEqual(noScheme.sharePath, "Public")
    let nfs = NetworkShare.cleanedServerInput("nfs://10.0.0.2//volume1/media")
    XCTAssertEqual(nfs.server, "10.0.0.2")
    XCTAssertEqual(nfs.sharePath, "volume1/media")
  }

  func testCleanedSharePathInputTrimsSlashes() {
    XCTAssertEqual(NetworkShare.cleanedSharePathInput("/Public/"), "Public")
    XCTAssertEqual(NetworkShare.cleanedSharePathInput(" Public/sub/ "), "Public/sub")
    XCTAssertEqual(NetworkShare.cleanedSharePathInput("Media"), "Media")
    XCTAssertEqual(NetworkShare.cleanedSharePathInput("/"), "")
  }

  func testPastedURLBuildsConnectionURLWithoutDoubleSlash() throws {
    let parts = NetworkShare.cleanedServerInput("smb://nas.local/Public")
    let share = NetworkShare(
      name: "Public", server: parts.server, sharePath: parts.sharePath, username: "")
    let url = try XCTUnwrap(NetworkMountPlan.connectionURL(for: share))
    XCTAssertEqual(url.absoluteString, "smb://nas.local/Public")
    let typed = NetworkShare(
      name: "Public", server: "nas.local",
      sharePath: NetworkShare.cleanedSharePathInput("/Public/"), username: "")
    XCTAssertEqual(
      try XCTUnwrap(NetworkMountPlan.connectionURL(for: typed)).absoluteString,
      "smb://nas.local/Public")
  }

  func testDisplayNameValidation() {
    XCTAssertNil(NetworkShare.displayNameValidationError("Media"))
    XCTAssertNil(NetworkShare.displayNameValidationError("My Share (2)"))
    XCTAssertNotNil(NetworkShare.displayNameValidationError("a/b"))
    XCTAssertNotNil(NetworkShare.displayNameValidationError("../Desktop"))
    XCTAssertNotNil(NetworkShare.displayNameValidationError("."))
    XCTAssertNotNil(NetworkShare.displayNameValidationError(".."))
  }

  func testResolvedDisplayNameTrimsAndFallsBackToTheSharePath() {
    XCTAssertEqual(NetworkShare.resolvedDisplayName(" NAS ", sharePath: "Public"), "NAS")
    XCTAssertEqual(NetworkShare.resolvedDisplayName("\tMy Share\n", sharePath: "x"), "My Share")
    XCTAssertEqual(NetworkShare.resolvedDisplayName("   ", sharePath: "Public"), "Public")
    XCTAssertEqual(NetworkShare.resolvedDisplayName("", sharePath: "export/Data"), "Data")
    XCTAssertEqual(NetworkShare.resolvedDisplayName("Media", sharePath: "Public"), "Media")
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

  func testNFSExportPathCaseMattersButSMBShareNameCaseDoesNot() {
    func share(_ path: String, _ shareProtocol: ShareProtocol) -> NetworkShare {
      NetworkShare(
        name: path, server: "nas.local", sharePath: path, username: "",
        shareProtocol: shareProtocol)
    }
    XCTAssertFalse(share("/export/Data", .nfs).hasSameEndpoint(as: share("/export/data", .nfs)))
    XCTAssertTrue(share("/export/Data", .nfs).hasSameEndpoint(as: share("export/Data/", .nfs)))
    XCTAssertTrue(share("Data", .smb).hasSameEndpoint(as: share("data", .smb)))
    XCTAssertTrue(share("Data", .afp).hasSameEndpoint(as: share("data", .afp)))
  }
}
