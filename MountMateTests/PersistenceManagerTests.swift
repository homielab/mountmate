import XCTest

@testable import MountMate

final class PersistenceManagerTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName = ""

  override func setUp() {
    super.setUp()
    suiteName = "PersistenceManagerTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  private struct EmptyFstabAccess: StartupBlockFstabAccess {
    func readContents() -> String { "" }
    func loadSnapshot() throws -> FstabWriter.Snapshot {
      FstabWriter.Snapshot(contents: "", raw: Data())
    }
    func install(_ contents: String, expectedCurrent: Data) async throws {}
    func startupBlockEligibility(forVolumeUUID uuid: String) -> FstabRules.StartupBlockEligibility {
      .notConnected
    }
    func customMountPointFileSystem(for volume: Volume) -> FstabRules.CustomMountPointFileSystem {
      .unknown
    }
  }

  /// Records what a custom mount point update reads and writes.
  private final class RecordingFstabAccess: StartupBlockFstabAccess {
    var contents = ""
    var fileSystem: FstabRules.CustomMountPointFileSystem = .supported("apfs")
    private(set) var snapshotLoads = 0
    private(set) var installed: [String] = []

    func readContents() -> String { contents }
    func loadSnapshot() throws -> FstabWriter.Snapshot {
      snapshotLoads += 1
      return FstabWriter.Snapshot(contents: contents, raw: Data(contents.utf8))
    }
    func install(_ newContents: String, expectedCurrent: Data) async throws {
      installed.append(newContents)
      contents = newContents
    }
    func startupBlockEligibility(forVolumeUUID uuid: String) -> FstabRules.StartupBlockEligibility {
      .notConnected
    }
    func customMountPointFileSystem(for volume: Volume) -> FstabRules.CustomMountPointFileSystem {
      fileSystem
    }
  }

  private func manager(saving shares: [NetworkShare]) -> PersistenceManager {
    let manager = PersistenceManager(defaults: defaults, fstabAccess: EmptyFstabAccess())
    shares.forEach(manager.addNetworkShare)
    return manager
  }

  private func share(
    server: String, path: String, shareProtocol: ShareProtocol = .smb
  ) -> NetworkShare {
    NetworkShare(
      name: "Share", server: server, sharePath: path, username: "",
      shareProtocol: shareProtocol)
  }

  // MARK: - containsNetworkShare(matching:)

  func testNFSExportsDifferingOnlyInCaseAreDifferentShares() {
    let manager = manager(saving: [share(server: "nas", path: "/export/Data", shareProtocol: .nfs)])

    XCTAssertFalse(
      manager.containsNetworkShare(
        matching: share(server: "nas", path: "/export/data", shareProtocol: .nfs)))
    XCTAssertTrue(
      manager.containsNetworkShare(
        matching: share(server: "NAS", path: "export/Data/", shareProtocol: .nfs)))
  }

  func testSMBSharesDifferingOnlyInCaseAreTheSameShare() {
    let manager = manager(saving: [share(server: "nas", path: "Public")])

    XCTAssertTrue(manager.containsNetworkShare(matching: share(server: "nas", path: "public")))
  }

  func testSMBAndNFSOnTheSameServerAndPathAreDifferentShares() {
    let manager = manager(saving: [share(server: "nas", path: "data")])

    XCTAssertFalse(
      manager.containsNetworkShare(
        matching: share(server: "nas", path: "data", shareProtocol: .nfs)))
  }

  func testServerPortIsIgnored() {
    let manager = manager(saving: [share(server: "nas", path: "Public")])

    XCTAssertTrue(manager.containsNetworkShare(matching: share(server: "nas:445", path: "Public")))
  }

  func testImportSkipsOnlyTheMatchingShare() {
    let manager = manager(saving: [share(server: "nas", path: "/export/Data", shareProtocol: .nfs)])

    let added = manager.addNetworkSharesIfNeeded([
      share(server: "nas", path: "/export/Data", shareProtocol: .nfs),
      share(server: "nas", path: "/export/data", shareProtocol: .nfs),
    ])

    XCTAssertEqual(added, 1)
    XCTAssertEqual(manager.networkShares.map(\.sharePath), ["/export/Data", "/export/data"])
  }

  // MARK: - Custom mount points: file system allowlist

  private let volumeUUID = "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6"

  private func externalVolume() -> Volume {
    Volume(
      id: volumeUUID, deviceIdentifier: "disk4s1", diskUUID: nil, name: "Data",
      isMounted: true, mountPoint: "/Volumes/Data", freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: nil, fileSystemType: "Microsoft Basic Data",
      usagePercentage: nil, category: .user, isProtected: false, snapshots: [],
      storageError: nil)
  }

  private func apply(
    _ mountPoint: String, with access: RecordingFstabAccess
  ) -> (PersistenceManager, PersistenceManager.CustomMountPointUpdateResult?) {
    let manager = PersistenceManager(defaults: defaults, fstabAccess: access)
    let done = expectation(description: "custom mount point applied")
    var result: PersistenceManager.CustomMountPointUpdateResult?
    manager.applyCustomMountPoint(mountPoint, for: externalVolume()) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return (manager, result)
  }

  func testNTFSAndThirdPartyDriversAreRefusedWithoutTouchingFstab() {
    for name in ["NTFS", "ext4"] {
      let access = RecordingFstabAccess()
      access.fileSystem = .unsupported(name: name)
      let (manager, result) = apply("/Users/me/Data", with: access)

      guard case .failure(let message) = result else {
        return XCTFail("\(name): expected a failure, got \(String(describing: result))")
      }
      XCTAssertTrue(message.contains(name), message)
      XCTAssertEqual(access.snapshotLoads, 0, name)
      XCTAssertEqual(access.installed, [], name)
      XCTAssertTrue(manager.customMountPoints.isEmpty, name)
    }
  }

  func testBuiltInFileSystemsGetTheirRule() {
    for type in ["apfs", "hfs", "exfat", "msdos"] {
      let access = RecordingFstabAccess()
      access.fileSystem = .supported(type)
      let (manager, result) = apply("/Users/me/Data", with: access)

      XCTAssertEqual(result, .success, type)
      XCTAssertEqual(access.installed.count, 1, type)
      XCTAssertTrue(
        access.installed.first?.contains("UUID=\(volumeUUID) /Users/me/Data \(type) rw") ?? false,
        type)
      XCTAssertEqual(manager.customMountPoints.map(\.mountPoint), ["/Users/me/Data"], type)
    }
  }

  func testUnsafeRuleFromAnOlderVersionIsListedAndRemovedOnlyWhenAsked() {
    let access = RecordingFstabAccess()
    access.contents = """
      UUID=0E2B5C1A-3D4F-4A5B-8C6D-7E8F9A0B1C2D none hfs rw,noauto
      # MountMate custom mount: NONE-\(volumeUUID)
      UUID=\(volumeUUID) /Volumes/Win ntfs rw
      """
    let manager = PersistenceManager(defaults: defaults, fstabAccess: access)

    XCTAssertEqual(
      manager.unsupportedCustomMountRules,
      [
        FstabRules.CustomMountRule(
          identifier: "NONE-\(volumeUUID)", volumeUUID: volumeUUID, mountPoint: "/Volumes/Win",
          fileSystemType: "ntfs")
      ])
    XCTAssertEqual(access.installed, [], "nothing is written at launch")

    let done = expectation(description: "rule removed")
    var result: PersistenceManager.CustomMountPointUpdateResult?
    manager.removeUnsupportedCustomMountRule(manager.unsupportedCustomMountRules[0]) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)

    XCTAssertEqual(result, .success)
    XCTAssertEqual(
      access.installed, ["UUID=0E2B5C1A-3D4F-4A5B-8C6D-7E8F9A0B1C2D none hfs rw,noauto\n"])
    XCTAssertEqual(manager.unsupportedCustomMountRules, [])
  }
}
