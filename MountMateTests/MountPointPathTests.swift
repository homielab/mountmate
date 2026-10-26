import XCTest

@testable import MountMate

final class MountPointPathTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("MountPointPathTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func error(_ path: String, mountedVolume: String? = nil) -> String? {
    DriveManager.customMountPointValidationError(for: path) { _ in mountedVolume }
  }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
  }

  // MARK: - Custom mount points

  func testNormalizedPathTrimsAndExpandsTilde() {
    XCTAssertEqual(
      DriveManager.normalizedMountPointPath("  ~/Mounts/Backup \n"),
      NSHomeDirectory() + "/Mounts/Backup")
    XCTAssertEqual(DriveManager.normalizedMountPointPath("/Volumes/X"), "/Volumes/X")
  }

  func testRejectsEmptyRelativeAndRootPaths() {
    XCTAssertEqual(error("   "), localized("Custom Mount Point Empty Path"))
    XCTAssertEqual(error("Mounts/Backup"), localized("Custom Mount Point Must Be Absolute"))
    XCTAssertEqual(error(" / "), localized("Custom Mount Point Cannot Be Root"))
  }

  func testRejectsControlCharacters() {
    XCTAssertEqual(
      error("/Volumes/a\nb"), localized("Custom Mount Point Control Characters"))
  }

  func testRejectsPathInUseByAnotherVolume() {
    var lookedUp: String?
    let message = DriveManager.customMountPointValidationError(for: " ~/Backup ") { path in
      lookedUp = path
      return "Other Disk"
    }
    XCTAssertEqual(lookedUp, NSHomeDirectory() + "/Backup")
    XCTAssertEqual(
      message, String(format: localized("Custom Mount Point In Use"), "Other Disk"))
  }

  func testRejectsExistingFileAndAcceptsFolderOrNewPath() throws {
    let file = scratch.appendingPathComponent("file.txt")
    try Data("x".utf8).write(to: file)

    XCTAssertEqual(error(file.path), localized("Custom Mount Point Must Be Folder"))
    XCTAssertNil(error(scratch.path))
    XCTAssertNil(error(scratch.appendingPathComponent("new").path))
  }

  // MARK: - Network shares

  private func share(name: String = "Media", customMountPoint: String? = nil) -> NetworkShare {
    NetworkShare(
      name: name, server: "nas.local", sharePath: "media", username: "",
      customMountPoint: customMountPoint)
  }

  func testConfiguredMountPointDefaultsToMountmateFolder() {
    XCTAssertEqual(
      NetworkMountManager.configuredMountPoint(for: share(), homeDirectory: "/Users/test"),
      "/Users/test/mountmate/Media")
    XCTAssertEqual(
      NetworkMountManager.configuredMountPoint(
        for: share(customMountPoint: ""), homeDirectory: "/Users/test"),
      "/Users/test/mountmate/Media")
  }

  func testConfiguredMountPointUsesCustomPath() {
    XCTAssertEqual(
      NetworkMountManager.configuredMountPoint(
        for: share(customMountPoint: "/Volumes/NAS"), homeDirectory: "/Users/test"),
      "/Volumes/NAS")
    XCTAssertEqual(
      NetworkMountManager.configuredMountPoint(
        for: share(customMountPoint: "Shares/NAS"), homeDirectory: "/Users/test"),
      "/Users/test/Shares/NAS")
    XCTAssertEqual(
      NetworkMountManager.configuredMountPoint(
        for: share(customMountPoint: "~/NAS"), homeDirectory: "/Users/test"),
      NSHomeDirectory() + "/NAS")
  }

  func testNormalizedHostStripsSchemeUserPortAndCase() {
    XCTAssertEqual(
      MountedNetworkShare.normalizedHost(" smb://Bob@NAS.example.com:445/share "),
      "nas.example.com")
    XCTAssertEqual(MountedNetworkShare.normalizedHost("//user%40corp@fileserver./x"), "fileserver")
    XCTAssertEqual(MountedNetworkShare.normalizedHost("192.168.1.10:139"), "192.168.1.10")
  }

  func testNormalizedHostHandlesIPv6AndBonjourNames() {
    XCTAssertEqual(MountedNetworkShare.normalizedHost("[fe80::1%25en0]:445"), "fe80::1%en0")
    XCTAssertEqual(MountedNetworkShare.normalizedHost("fe80::1"), "fe80::1")
    XCTAssertEqual(MountedNetworkShare.normalizedHost("NAS._smb._tcp.local"), "nas")
    XCTAssertEqual(MountedNetworkShare.normalizedHost("nas.local"), "nas")
  }
}
