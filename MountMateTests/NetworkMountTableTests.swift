//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkMountTableTests: XCTestCase {
  private func mount(_ source: String, at mountPoint: String, _ fileSystemType: String)
    throws -> MountedNetworkShare
  {
    try XCTUnwrap(
      MountedNetworkShare(source: source, mountPoint: mountPoint, fileSystemType: fileSystemType))
  }

  private func parse(
    _ mounts: [MountedNetworkShare], saved: [NetworkShare],
    cache: inout [String: NetworkShare]
  ) -> NetworkMountTable.Parsed {
    let owners = ShareAdoption.attributeMounts(mounts, to: saved, adoptions: [:]).owners
    return NetworkMountTable.parse(
      mounts, savedShares: saved, owners: owners, manualShareCache: &cache, localize: { $0 })
  }

  func testSMBAFPAndNFSMountsAreSplitIntoSavedAndManual() throws {
    let saved = NetworkShare(name: "docs", server: "nas", sharePath: "docs", username: "me")
    let mounts = [
      try mount("//me@nas/docs", at: "/Users/me/mountmate/docs", "smbfs"),
      try mount("//other@mac.local/Media", at: "/Volumes/Media", "afpfs"),
      try mount("server:/export/backup", at: "/Volumes/backup", "nfs"),
    ]
    var cache: [String: NetworkShare] = [:]

    let parsed = parse(mounts, saved: [saved], cache: &cache)

    XCTAssertEqual(parsed.mountedShareIDs, [saved.id])
    XCTAssertEqual(parsed.manualShares.map(\.name), ["Media", "backup"])
    XCTAssertEqual(parsed.manualShares.map(\.shareProtocol), [.afp, .nfs])
    XCTAssertEqual(parsed.mountPoints[saved.id], "/Users/me/mountmate/docs")
    for manual in parsed.manualShares {
      XCTAssertNotNil(parsed.mountPoints[manual.id])
    }
  }

  func testMountPointWithSpacesIsKeptWhole() throws {
    let mounts = [try mount("//nas/My Documents", at: "/Volumes/My Documents", "smbfs")]
    var cache: [String: NetworkShare] = [:]

    let parsed = parse(mounts, saved: [], cache: &cache)

    let manual = try XCTUnwrap(parsed.manualShares.first)
    XCTAssertEqual(manual.sharePath, "My Documents")
    XCTAssertEqual(parsed.mountPoints[manual.id], "/Volumes/My Documents")
  }

  func testSameSharePathOnAnotherHostIsNotTheSavedShare() throws {
    let saved = NetworkShare(name: "public", server: "nas", sharePath: "public", username: "")
    let mounts = [try mount("//other-nas/public", at: "/Volumes/public", "smbfs")]
    var cache: [String: NetworkShare] = [:]

    let parsed = parse(mounts, saved: [saved], cache: &cache)

    XCTAssertTrue(parsed.mountedShareIDs.isEmpty)
    XCTAssertEqual(parsed.manualShares.map(\.server), ["other-nas"])
  }

  func testManualShareKeepsItsIDWhileMountedAndIsForgottenAfter() throws {
    let mounts = [try mount("//nas/public", at: "/Volumes/public", "smbfs")]
    var cache: [String: NetworkShare] = [:]

    let first = parse(mounts, saved: [], cache: &cache)
    let second = parse(mounts, saved: [], cache: &cache)
    XCTAssertEqual(first.manualShares.map(\.id), second.manualShares.map(\.id))

    _ = parse([], saved: [], cache: &cache)
    XCTAssertTrue(cache.isEmpty)
    let third = parse(mounts, saved: [], cache: &cache)
    XCTAssertNotEqual(first.manualShares.map(\.id), third.manualShares.map(\.id))
  }

  func testManualShareContainingDroppedURL() throws {
    let share = NetworkShare(name: "public", server: "nas", sharePath: "public", username: "")
    let mountPoints = [share.id: "/Volumes/public"]

    func owner(_ path: String) -> NetworkShare? {
      NetworkMountTable.manualShare(
        containing: URL(fileURLWithPath: path), in: [share], mountPoints: mountPoints)
    }
    XCTAssertEqual(owner("/Volumes/public")?.id, share.id)
    XCTAssertEqual(owner("/Volumes/public/folder/file.txt")?.id, share.id)
    XCTAssertNil(owner("/Volumes/public2/file.txt"))
    XCTAssertNil(owner("/Volumes/other"))
  }

  func testMountsOfShareUsesCurrentShareAndAdoptions() throws {
    let share = NetworkShare(name: "NAS", server: "nas", sharePath: "public", username: "")
    let ipMount = try mount("//192.168.1.5/public", at: "/Volumes/public", "smbfs")
    let exact = try mount("//nas/public", at: "/Users/me/mountmate/NAS", "smbfs")

    XCTAssertTrue(
      NetworkMountTable.mounts(of: share, in: [ipMount], savedShares: [], adoptions: [:]).isEmpty)

    let adoption = ShareAdoption()
    adoption.adopt("/Volumes/public", for: share)
    _ = adoption.parse([ipMount], savedShares: [share])
    XCTAssertEqual(
      adoption.mounts(of: share, in: [ipMount, exact]).map(\.mountPoint),
      ["/Users/me/mountmate/NAS"])
  }

  func testLiveMountPointPrefersLastKnown() throws {
    let a = try mount("//nas/public", at: "/Volumes/public", "smbfs")
    let b = try mount("//nas/public", at: "/Users/me/mountmate/public", "smbfs")

    XCTAssertEqual(
      NetworkMountTable.liveMountPoint(of: [a, b], lastKnown: "/users/me/mountmate/public/"),
      "/Users/me/mountmate/public")
    XCTAssertEqual(NetworkMountTable.liveMountPoint(of: [a, b], lastKnown: "/gone"), a.mountPoint)
    XCTAssertEqual(NetworkMountTable.liveMountPoint(of: [a], lastKnown: nil), a.mountPoint)
    XCTAssertNil(NetworkMountTable.liveMountPoint(of: [], lastKnown: "/Volumes/public"))
  }
}
