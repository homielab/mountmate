//  Created by homielab.com

import XCTest

@testable import MountMate

final class NetworkServiceResolverTests: XCTestCase {
  private func service(_ name: String, _ type: String) -> DiscoveredShareService {
    DiscoveredShareService(name: name, type: type)
  }

  // MARK: protocol mapping

  func testMapsBonjourTypesToShareProtocols() {
    XCTAssertEqual(NetworkServiceResolver.shareProtocol(for: "_smb._tcp"), .smb)
    XCTAssertEqual(NetworkServiceResolver.shareProtocol(for: "_nfs._tcp."), .nfs)
    XCTAssertEqual(NetworkServiceResolver.shareProtocol(for: "_SMB._TCP"), .smb)
    XCTAssertNil(NetworkServiceResolver.shareProtocol(for: "_afp._tcp"))
    XCTAssertNil(NetworkServiceResolver.shareProtocol(for: "_ipp._tcp"))
    XCTAssertNil(NetworkServiceResolver.shareProtocol(for: "junk"))
  }

  func testBrowsedTypesAreTheShareTypes() {
    XCTAssertEqual(
      NetworkServiceResolver.browsedTypes, ["_smb._tcp", "_nfs._tcp"])
  }

  // MARK: host names

  func testHostFromServiceNameStripsDomainAndWhitespace() {
    XCTAssertEqual(NetworkServiceResolver.hostFromServiceName("MyNAS"), "MyNAS")
    XCTAssertEqual(NetworkServiceResolver.hostFromServiceName("MyNAS.local."), "MyNAS")
    XCTAssertEqual(NetworkServiceResolver.hostFromServiceName("  My NAS  "), "My NAS")
    XCTAssertEqual(NetworkServiceResolver.hostFromServiceName(""), "")
  }

  // MARK: resolve

  func testResolveBuildsEntriesWithHostAndProtocol() {
    let resolved = NetworkServiceResolver.resolve([
      service("Photos NAS", "_smb._tcp"),
      service("Backups", "_nfs._tcp"),
    ])
    XCTAssertEqual(
      resolved,
      [
        BrowsedShareService(host: "Backups", shareProtocol: .nfs, displayName: "Backups"),
        BrowsedShareService(host: "Photos NAS", shareProtocol: .smb, displayName: "Photos NAS"),
      ])
  }

  func testResolveDropsUnknownTypesAndEmptyNames() {
    let resolved = NetworkServiceResolver.resolve([
      service("Printer", "_ipp._tcp"),
      service("", "_smb._tcp"),
      service("Real", "_smb._tcp"),
    ])
    XCTAssertEqual(resolved.map(\.host), ["Real"])
  }

  func testResolveCollapsesDuplicatesAcrossInterfaces() {
    let resolved = NetworkServiceResolver.resolve([
      service("NAS", "_smb._tcp"),
      service("NAS", "_smb._tcp"),  // announced on a second interface
      service("nas", "_smb._tcp"),  // same host, different case
    ])
    XCTAssertEqual(resolved.count, 1)
    XCTAssertEqual(resolved.first?.host, "NAS")
  }

  func testSameHostAnnouncingSMBAndNFSGivesTwoEntries() {
    let resolved = NetworkServiceResolver.resolve([
      service("NAS", "_smb._tcp"),
      service("NAS", "_nfs._tcp"),
    ])
    XCTAssertEqual(resolved.map(\.shareProtocol), [.smb, .nfs])
  }

  func testResolveSortsByDisplayNameCaseInsensitively() {
    let resolved = NetworkServiceResolver.resolve([
      service("zeta", "_smb._tcp"),
      service("Alpha", "_smb._tcp"),
      service("beta", "_smb._tcp"),
    ])
    XCTAssertEqual(resolved.map(\.host), ["Alpha", "beta", "zeta"])
  }

  func testResolveEmptyListGivesNoEntries() {
    XCTAssertEqual(NetworkServiceResolver.resolve([]), [])
  }
}
