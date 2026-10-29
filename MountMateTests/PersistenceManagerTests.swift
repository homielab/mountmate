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
}
