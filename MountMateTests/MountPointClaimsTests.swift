//  Created by homielab.com

import XCTest

@testable import MountMate

final class MountPointClaimsTests: XCTestCase {
  private func entry(_ name: String, uuid: String, path: String) -> VolumeCustomMountPoint {
    VolumeCustomMountPoint(
      volumeUUID: uuid, backingDiskIdentifier: "disk-\(uuid)", name: name, mountPoint: path)
  }

  private func volumeError(_ path: String, entries: [VolumeCustomMountPoint], self key: String?)
    -> String?
  {
    CustomMountPointValidator.validationError(
      for: path,
      savedClaim: {
        MountPointClaims.error(
          for: $0, in: MountPointClaims.volumeClaims(entries), excludingKey: key)
      },
      mountedVolumeName: { _ in nil })
  }

  private func usedByVolume(_ name: String) -> String {
    String(format: NSLocalizedString("Mount Point Used By Volume", comment: ""), name)
  }

  private func usedByShare(_ name: String) -> String {
    String(format: NSLocalizedString("Mount Point Used By Share", comment: ""), name)
  }

  func testAnotherVolumesSavedPathIsRefusedWithItsName() {
    let a = entry("Backup", uuid: "A", path: "/Volumes/X")
    XCTAssertEqual(volumeError("/Volumes/X", entries: [a], self: "other"), usedByVolume("Backup"))
  }

  func testTrailingSlashAndCaseStillClash() {
    let a = entry("Backup", uuid: "A", path: "/Volumes/X")
    XCTAssertEqual(volumeError("/volumes/x/", entries: [a], self: nil), usedByVolume("Backup"))
  }

  func testAVolumeMayKeepItsOwnPath() {
    let a = entry("Backup", uuid: "A", path: "/Volumes/X")
    XCTAssertNil(volumeError("/Volumes/X", entries: [a], self: a.id))
  }

  func testADifferentPathIsAccepted() {
    let a = entry("Backup", uuid: "A", path: "/Volumes/X")
    XCTAssertNil(volumeError("/Volumes/Y", entries: [a], self: nil))
  }

  func testAVolumeOnAShareFolderIsRefused() {
    let nas = NetworkShare(name: "NAS", server: "nas.local", sharePath: "media", username: "")
    let claims = MountPointClaims.shareClaims([nas]) { _ in "/Users/test/mountmate/NAS" }
    XCTAssertEqual(
      MountPointClaims.error(for: "/Users/test/mountmate/nas/", in: claims, excludingKey: "x"),
      usedByShare("NAS"))
  }

  func testAShareOnAVolumeFolderIsRefused() {
    var nas = NetworkShare(name: "NAS", server: "nas.local", sharePath: "media", username: "")
    nas.customMountPoint = "/Volumes/X/"
    let claims = MountPointClaims.volumeClaims([entry("Backup", uuid: "A", path: "/Volumes/x")])
    XCTAssertEqual(
      NetworkShareValidation.error(
        candidate: nas, original: nil, otherShares: [], mountPoint: { $0.customMountPoint ?? "" },
        volumeClaims: claims),
      usedByVolume("Backup"))
    nas.customMountPoint = "/Volumes/Y"
    XCTAssertNil(
      NetworkShareValidation.error(
        candidate: nas, original: nil, otherShares: [], mountPoint: { $0.customMountPoint ?? "" },
        volumeClaims: claims))
  }
}
