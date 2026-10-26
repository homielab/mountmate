//  Created by homielab.com

import XCTest

@testable import MountMate

final class DiskEventFilterTests: XCTestCase {
  private let table = [
    MountEntry(source: "/dev/disk3s1s1", mountPoint: "/", fileSystemType: "apfs"),
    MountEntry(source: "/dev/disk4s1", mountPoint: "/Volumes/USB", fileSystemType: "exfat"),
    MountEntry(source: "//bob@nas/media", mountPoint: "/Volumes/media", fileSystemType: "smbfs"),
    MountEntry(source: "nas:/export", mountPoint: "/Volumes/export", fileSystemType: "nfs"),
    MountEntry(source: "x", mountPoint: "/Volumes/afp", fileSystemType: "afpfs"),
    MountEntry(source: "http://x", mountPoint: "/Volumes/dav", fileSystemType: "webdav"),
  ]

  private func isLocal(_ path: String?, known: Set<String> = [], entries: [MountEntry]? = nil)
    -> Bool
  {
    DiskEventFilter.isLocalDiskEvent(
      volumeURL: path.map { URL(fileURLWithPath: $0) }, entries: entries ?? table,
      knownNetworkMountPoints: known)
  }

  func testNetworkSharesAreNotLocalDiskEvents() {
    for path in ["/Volumes/media", "/Volumes/export", "/Volumes/afp", "/Volumes/dav"] {
      XCTAssertFalse(isLocal(path), path)
    }
  }

  func testLocalVolumesAreLocalDiskEvents() {
    XCTAssertTrue(isLocal("/Volumes/USB"))
    XCTAssertTrue(isLocal("/"))
  }

  func testUnmountedShareIsRecognisedFromThePreviousTable() {
    let withoutShare = table.filter { $0.mountPoint != "/Volumes/media" }
    XCTAssertFalse(isLocal("/Volumes/media", known: ["/Volumes/media"], entries: withoutShare))
    XCTAssertTrue(isLocal("/Volumes/media", entries: withoutShare))
  }

  func testUnknownEventsStillRefresh() {
    XCTAssertTrue(isLocal(nil))
    XCTAssertTrue(
      DiskEventFilter.isLocalDiskEvent(
        volumeURL: URL(fileURLWithPath: "/Volumes/media"), entries: nil,
        knownNetworkMountPoints: []))
  }

  func testNetworkMountPointsOnlyContainNetworkTypes() {
    XCTAssertEqual(
      DiskEventFilter.networkMountPoints(in: table),
      ["/Volumes/media", "/Volumes/export", "/Volumes/afp", "/Volumes/dav"])
  }
}
