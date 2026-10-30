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

  func testFallbackHostTurnsTheServiceNameIntoALocalHostName() {
    let fallback = NetworkServiceResolver.fallbackHost(forServiceName:)
    XCTAssertEqual(fallback("  My NAS  "), "my-nas.local")
    XCTAssertEqual(fallback("MyNAS"), "mynas.local")
    XCTAssertEqual(fallback("MyNAS.local."), "mynas.local")
    XCTAssertEqual(fallback("John's MacBook Pro"), "johns-macbook-pro.local")
    XCTAssertEqual(fallback("John\u{2019}s MacBook Pro"), "johns-macbook-pro.local")
    XCTAssertEqual(fallback("NAS (Office) #2"), "nas-office-2.local")
    XCTAssertEqual(fallback("Máy chủ Đức"), "may-chu-duc.local")
    XCTAssertEqual(fallback(""), "")
    XCTAssertEqual(fallback(" 💾 "), "")
  }

  func testFallbackHostNeverContainsSpacesOrApostrophes() {
    for name in ["My NAS", "John's MacBook Pro", "a  b\tc", "'quoted'", "x.local. "] {
      let host = NetworkServiceResolver.fallbackHost(forServiceName: name)
      XCTAssertFalse(host.contains(" "), host)
      XCTAssertFalse(host.contains("'"), host)
      XCTAssertTrue(host.hasSuffix(".local"), host)
    }
  }

  func testHostFromHostTargetDropsTheRootDot() {
    let host = NetworkServiceResolver.host(fromHostTarget:)
    XCTAssertEqual(host("Johns-MacBook-Pro.local."), "Johns-MacBook-Pro.local")
    XCTAssertEqual(host("nas.example.com"), "nas.example.com")
    XCTAssertNil(host(""))
    XCTAssertNil(host("."))
    XCTAssertNil(host("My NAS.local."))
  }

  func testOnlyNonDefaultPortsAreKept() {
    XCTAssertNil(NetworkServiceResolver.nonDefaultPort(445, for: .smb))
    XCTAssertNil(NetworkServiceResolver.nonDefaultPort(2049, for: .nfs))
    XCTAssertNil(NetworkServiceResolver.nonDefaultPort(0, for: .smb))
    XCTAssertEqual(NetworkServiceResolver.nonDefaultPort(1445, for: .smb), 1445)
    XCTAssertEqual(NetworkServiceResolver.nonDefaultPort(445, for: .nfs), 445)
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
        BrowsedShareService(host: "backups.local", shareProtocol: .nfs, displayName: "Backups"),
        BrowsedShareService(
          host: "photos-nas.local", shareProtocol: .smb, displayName: "Photos NAS"),
      ])
  }

  func testResolveDropsUnknownTypesAndEmptyNames() {
    let resolved = NetworkServiceResolver.resolve([
      service("Printer", "_ipp._tcp"),
      service("", "_smb._tcp"),
      service("Real", "_smb._tcp"),
    ])
    XCTAssertEqual(resolved.map(\.host), ["real.local"])
  }

  func testResolveCollapsesDuplicatesAcrossInterfaces() {
    let resolved = NetworkServiceResolver.resolve([
      service("NAS", "_smb._tcp"),
      service("NAS", "_smb._tcp"),  // announced on a second interface
      service("nas", "_smb._tcp"),  // same host, different case
    ])
    XCTAssertEqual(resolved.count, 1)
    XCTAssertEqual(resolved.first?.host, "nas.local")
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
    XCTAssertEqual(resolved.map(\.displayName), ["Alpha", "beta", "zeta"])
  }

  func testResolvedHostWinsOverTheNameDerivedOne() {
    let mac = service("John's MacBook Pro", "_smb._tcp")
    let nas = service("My NAS", "_smb._tcp")
    let resolved = NetworkServiceResolver.resolve(
      [mac, nas],
      resolved: [mac: ResolvedServiceAddress(hostTarget: "Johns-MBP.local.", port: 445)])
    XCTAssertEqual(
      resolved,
      [
        BrowsedShareService(
          host: "Johns-MBP.local", shareProtocol: .smb, displayName: "John's MacBook Pro"),
        BrowsedShareService(host: "my-nas.local", shareProtocol: .smb, displayName: "My NAS"),
      ])
  }

  func testResolvedNonDefaultPortGoesIntoTheServerAddress() {
    let nas = service("NAS", "_smb._tcp")
    let resolved = NetworkServiceResolver.resolve(
      [nas], resolved: [nas: ResolvedServiceAddress(hostTarget: "nas.local.", port: 1445)])
    XCTAssertEqual(resolved.first?.serverAddress, "nas.local:1445")
    XCTAssertEqual(resolved.first?.id, "nas.local:1445-smb")
  }

  func testUnusableResolvedHostFallsBackToTheServiceName() {
    let nas = service("My NAS", "_smb._tcp")
    let resolved = NetworkServiceResolver.resolve(
      [nas], resolved: [nas: ResolvedServiceAddress(hostTarget: "", port: 445)])
    XCTAssertEqual(resolved.first?.serverAddress, "my-nas.local")
  }

  func testServerAddressHasNoSpacesOrApostrophes() {
    let resolved = NetworkServiceResolver.resolve([
      service("John's MacBook Pro", "_smb._tcp"),
      service("  My NAS  ", "_nfs._tcp"),
    ])
    for entry in resolved {
      XCTAssertFalse(entry.serverAddress.contains(" "), entry.serverAddress)
      XCTAssertFalse(entry.serverAddress.contains("'"), entry.serverAddress)
    }
  }

  func testResolveEmptyListGivesNoEntries() {
    XCTAssertEqual(NetworkServiceResolver.resolve([]), [])
  }
}
