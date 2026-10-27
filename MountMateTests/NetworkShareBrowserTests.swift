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
    XCTAssertEqual(hosts(browser), ["A", "B"])

    browser.handle(results: [service("A", smb)], type: smb)
    XCTAssertEqual(hosts(browser), ["A"])

    browser.handle(results: [], type: smb)
    XCTAssertTrue(browser.services.isEmpty)
  }

  func testEachBrowserKeepsItsOwnResults() {
    let browser = makeBrowser()
    browser.start()
    browser.handle(results: [service("A", smb)], type: smb)
    browser.handle(results: [service("B", nfs)], type: nfs)
    XCTAssertEqual(browser.services.map(\.id), ["a-smb", "b-nfs"])

    // An empty NFS batch removes only the NFS server.
    browser.handle(results: [], type: nfs)
    XCTAssertEqual(browser.services.map(\.id), ["a-smb"])
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
    XCTAssertEqual(hosts(browser), ["C"])
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
