//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkWebDAVTests: XCTestCase {
  private func share(
    _ server: String, _ path: String, user: String = "", secure: Bool = true
  ) -> NetworkShare {
    NetworkShare(
      name: "x", server: server, sharePath: path, username: user, shareProtocol: .webdav,
      secure: secure)
  }

  // MARK: - Address parsing

  func testPastedURLIsSplitForBothSchemes() {
    let https = NetworkShare.cleanedServerInput("https://me@cloud.example.com:8443/remote.php/dav")
    XCTAssertEqual(https.server, "cloud.example.com:8443")
    XCTAssertEqual(https.sharePath, "remote.php/dav")
    XCTAssertEqual(https.username, "me")
    XCTAssertEqual(NetworkShare.cleanedServerInput("HTTP://nas/home").server, "nas")
  }

  func testPastedSchemeDecidesTLS() {
    XCTAssertEqual(NetworkShare.pastedWebDAVSecurity("https://nas/x"), true)
    XCTAssertEqual(NetworkShare.pastedWebDAVSecurity(" http://nas/x"), false)
    XCTAssertNil(NetworkShare.pastedWebDAVSecurity("smb://nas/x"))
    XCTAssertNil(NetworkShare.pastedWebDAVSecurity("nas"))
  }

  func testProtocolMetadata() {
    XCTAssertEqual(ShareProtocol.from(mountFilesystemName: "webdav"), .webdav)
    XCTAssertTrue(ShareProtocol.webdav.supportsUserCredentials)
    XCTAssertTrue(ShareProtocol.creationCases.contains(.webdav))
  }

  // MARK: - Plan

  func testConnectionURLUsesTheSchemeAndKeepsACustomPort() {
    XCTAssertEqual(
      NetworkMountPlan.connectionURL(for: share("cloud.example.com", "dav/me"))?.absoluteString,
      "https://cloud.example.com/dav/me")
    XCTAssertEqual(
      NetworkMountPlan.connectionURL(for: share("nas:5005", "home", secure: false))?.absoluteString,
      "http://nas:5005/home")
  }

  func testPreviewNeverShowsAPassword() {
    XCTAssertEqual(
      NetworkMountPlan.connectionPreview(for: share("nas", "home", user: "me")),
      "https://nas/home")
  }

  func testUsernameGoesToNetFSAsAnArgument() {
    let placement = NetworkMountPlan.netFSUserPlacement(for: share("nas", "home", user: "me@corp"))
    XCTAssertNil(placement.urlUser)
    XCTAssertEqual(placement.user, "me@corp")
  }

  // MARK: - Mount table

  func testMountSourceIsParsedAsAnEndpoint() throws {
    let mounted = try XCTUnwrap(
      MountedNetworkShare(
        source: "https://Cloud.Example.com/remote.php/dav/files/me/",
        mountPoint: "/Users/me/mountmate/cloud", fileSystemType: "webdav"))
    XCTAssertEqual(mounted.shareProtocol, .webdav)
    XCTAssertEqual(
      mounted.endpoint,
      .init(host: "cloud.example.com", port: nil, path: "remote.php/dav/files/me"))
    XCTAssertTrue(mounted.matches(share("cloud.example.com:443", "remote.php/dav/files/me")))
    XCTAssertFalse(mounted.matches(share("cloud.example.com", "remote.php/dav/files/other")))
  }

  func testHTTPMountWithPortMatchesTheSavedShare() throws {
    let mounted = try XCTUnwrap(
      MountedNetworkShare(
        source: "http://nas:5005/home", mountPoint: "/Volumes/home", fileSystemType: "webdav"))
    XCTAssertTrue(mounted.matches(share("nas:5005", "home", secure: false)))
    XCTAssertFalse(mounted.matches(share("nas", "home", secure: false)))
  }

  func testImportedWebDAVMountKeepsSchemeUserAndPath() throws {
    let mounted = try XCTUnwrap(
      MountedNetworkShare(
        source: "http://me@nas:5005/home/docs", mountPoint: "/Volumes/docs",
        fileSystemType: "webdav"))
    let imported = NetworkMountTable.importedShare(from: mounted, localize: { $0 })
    XCTAssertEqual(imported.shareProtocol, .webdav)
    XCTAssertEqual(imported.server, "nas:5005")
    XCTAssertEqual(imported.sharePath, "home/docs")
    XCTAssertEqual(imported.username, "me")
    XCTAssertFalse(imported.secure)
  }

  // MARK: - Saved data and backup

  func testSavedSharesWithoutTheFlagDecodeAsHTTPS() throws {
    let json = """
      {"id":"\(UUID().uuidString)","name":"a","server":"nas","sharePath":"p","username":"",
       "mountAtLogin":true,"shareProtocol":"webdav"}
      """
    let decoded = try JSONDecoder().decode(NetworkShare.self, from: Data(json.utf8))
    XCTAssertTrue(decoded.secure)
  }

  func testBackupFileKeepsPlainHTTPAndReadsAPastedURL() throws {
    let data = try NetworkShareBackup.encode([share("nas:5005", "home", secure: false)])
    let plan = try NetworkShareBackup.importPlan(
      from: data, existing: [], mountPoint: { _ in "/tmp/none" })
    XCTAssertEqual(plan.shares.first?.secure, false)

    let handWritten = """
      {"format":"mountmate.networkShares","version":1,
       "shares":[{"protocol":"webdav","server":"http://nas/home"}]}
      """
    let pasted = try NetworkShareBackup.importPlan(
      from: Data(handWritten.utf8), existing: [], mountPoint: { _ in "/tmp/none" })
    XCTAssertEqual(pasted.shares.first?.server, "nas")
    XCTAssertEqual(pasted.shares.first?.sharePath, "home")
    XCTAssertEqual(pasted.shares.first?.secure, false)
  }
}
