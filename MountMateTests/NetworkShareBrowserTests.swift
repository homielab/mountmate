//  Created by homielab.com

import XCTest

@testable import MountMate

@MainActor
final class NetworkShareBrowserTests: XCTestCase {
  private let smb = "_smb._tcp"
  private let nfs = "_nfs._tcp"

  private func makeBrowser() -> NetworkShareBrowser {
    NetworkShareBrowser(foundGracePeriod: 60, browsesNetwork: false)
  }

  private func service(_ name: String, _ type: String) -> DiscoveredShareService {
    DiscoveredShareService(name: name, type: type)
  }

  private func hosts(_ browser: NetworkShareBrowser) -> [String] {
    browser.services.map(\.host)
  }

  func testServerThatLeavesBonjourDisappears() {
    let browser = makeBrowser()
    browser.start()
    browser.handle(results: [service("A", smb), service("B", smb)], type: smb)
    XCTAssertEqual(hosts(browser), ["a.local", "b.local"])

    browser.handle(results: [service("A", smb)], type: smb)
    XCTAssertEqual(hosts(browser), ["a.local"])

    browser.handle(results: [], type: smb)
    XCTAssertTrue(browser.services.isEmpty)
  }

  func testEachBrowserKeepsItsOwnResults() {
    let browser = makeBrowser()
    browser.start()
    browser.handle(results: [service("A", smb)], type: smb)
    browser.handle(results: [service("B", nfs)], type: nfs)
    XCTAssertEqual(browser.services.map(\.id), ["a.local-smb", "b.local-nfs"])

    // An empty NFS batch removes only the NFS server.
    browser.handle(results: [], type: nfs)
    XCTAssertEqual(browser.services.map(\.id), ["a.local-smb"])
  }

  func testFoundServicesEndTheSpinner() {
    let browser = makeBrowser()
    browser.start()
    XCTAssertTrue(browser.isBrowsing)
    browser.handle(results: [service("A", smb)], type: smb)
    XCTAssertFalse(browser.isBrowsing)
  }

  func testResultsAfterStopAreIgnored() {
    let browser = makeBrowser()
    browser.start()
    browser.handle(results: [service("A", smb)], type: smb)
    browser.stop()

    browser.handle(results: [service("B", smb)], type: smb)
    XCTAssertTrue(browser.services.isEmpty)
    XCTAssertFalse(browser.isBrowsing)
    XCTAssertFalse(browser.failed)
  }

  func testRestartDoesNotShowThePreviousSession() {
    let browser = makeBrowser()
    browser.start()
    browser.handle(results: [service("A", smb)], type: smb)
    browser.handle(results: [service("B", nfs)], type: nfs)
    browser.stop()

    browser.start()
    XCTAssertTrue(browser.services.isEmpty)
    XCTAssertTrue(browser.isBrowsing)
    browser.handle(results: [service("C", smb)], type: smb)
    XCTAssertEqual(hosts(browser), ["c.local"])
  }

  func testResolvedHostReplacesTheNameDerivedOne() {
    let browser = makeBrowser()
    browser.start()
    let nas = service("My NAS", smb)
    browser.handle(results: [nas], type: smb)
    XCTAssertEqual(hosts(browser), ["my-nas.local"])

    browser.handle(
      resolved: ResolvedServiceAddress(hostTarget: "DS920.local.", port: 445), for: nas)
    XCTAssertEqual(browser.services.map(\.serverAddress), ["DS920.local"])
    XCTAssertEqual(browser.services.first?.displayName, "My NAS")

    // A later result batch keeps the resolved host.
    browser.handle(results: [nas], type: smb)
    XCTAssertEqual(hosts(browser), ["DS920.local"])
  }

  func testResolvedAddressAfterStopIsIgnored() {
    let browser = makeBrowser()
    browser.start()
    let nas = service("NAS", smb)
    browser.handle(results: [nas], type: smb)
    browser.stop()
    browser.handle(
      resolved: ResolvedServiceAddress(hostTarget: "other.local.", port: 445), for: nas)
    XCTAssertTrue(browser.services.isEmpty)

    // A new session starts from the name-derived host again.
    browser.start()
    browser.handle(results: [nas], type: smb)
    XCTAssertEqual(hosts(browser), ["nas.local"])
  }

  func testGracePeriodEndsSpinnerWhenNothingFound() {
    let browser = NetworkShareBrowser(foundGracePeriod: 0.05, browsesNetwork: false)
    browser.start()
    let expectation = expectation(description: "grace period")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
    wait(for: [expectation], timeout: 2)
    XCTAssertFalse(browser.isBrowsing)
  }

  func testStopCancelsTheGracePeriod() {
    // The first session's timer would fire at 0.3 s, the second's at 0.5 s:
    // at 0.4 s the restarted picker must still be browsing.
    let browser = NetworkShareBrowser(foundGracePeriod: 0.3, browsesNetwork: false)
    browser.start()
    browser.stop()
    let checked = expectation(description: "checked between the two timers")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      browser.start()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        XCTAssertTrue(browser.isBrowsing)
        browser.stop()
        checked.fulfill()
      }
    }
    wait(for: [checked], timeout: 3)
  }
}
