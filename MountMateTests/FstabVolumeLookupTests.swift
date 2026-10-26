//  Created by homielab.com

import XCTest

@testable import MountMate

final class FstabVolumeLookupTests: XCTestCase {
  private let externalUUID = "11111111-2222-3333-4444-555555555555"
  private let exfatUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

  private func fixture(_ name: String) throws -> String {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: name, withExtension: "plist"),
      "\(name).plist fixture missing from the test bundle")
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func ok(_ stdout: String) -> ProcessResult {
    ProcessResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
  }

  private let failure = ProcessResult(stdout: "", stderr: "boom", exitCode: 1, timedOut: false)

  /// Answers `diskutil info -plist <id>` and `diskutil apfs list -plist <id>`
  /// from fixtures and records every call.
  private func makeLookup(
    info: [String: String], apfsList: String?, calls: UnsafeMutablePointer<[[String]]>? = nil
  ) -> FstabVolumeLookup {
    nonisolated(unsafe) var log: [[String]] = []
    return FstabVolumeLookup { executable, arguments in
      XCTAssertEqual(executable, "/usr/sbin/diskutil")
      log.append(arguments)
      calls?.pointee = log
      if arguments.starts(with: ["info", "-plist"]) {
        return info[arguments[2]].map(self.ok) ?? self.failure
      }
      if arguments.starts(with: ["apfs", "list", "-plist"]) {
        return apfsList.map(self.ok) ?? self.failure
      }
      XCTFail("unexpected diskutil call \(arguments)")
      return self.failure
    }
  }

  func testExternalAPFSVolumeWithNoRolesIsEligible() throws {
    let lookup = makeLookup(
      info: [
        externalUUID: try fixture("diskutilInfoExternalAPFS"),
        "/": try fixture("diskutilInfoBoot"),
      ],
      apfsList: try fixture("apfsListExternal"))
    XCTAssertEqual(
      lookup.startupBlockEligibility(forVolumeUUID: externalUUID),
      .eligible(fileSystemType: "apfs"))
  }

  func testAPFSVolumeWithSystemRoleIsIneligible() throws {
    let lookup = makeLookup(
      info: [
        "99999999-2222-3333-4444-555555555555": try fixture("diskutilInfoExternalAPFS"),
        "/": try fixture("diskutilInfoBoot"),
      ],
      apfsList: try fixture("apfsListExternal"))
    XCTAssertEqual(
      lookup.startupBlockEligibility(forVolumeUUID: "99999999-2222-3333-4444-555555555555"),
      .ineligible("it has a macOS system role"))
  }

  func testVolumeInTheStartupContainerIsIneligible() throws {
    let lookup = makeLookup(
      info: [
        externalUUID: try fixture("diskutilInfoBoot"),
        "/": try fixture("diskutilInfoBoot"),
      ],
      apfsList: try fixture("apfsListExternal"))
    guard case .ineligible = lookup.startupBlockEligibility(forVolumeUUID: externalUUID) else {
      return XCTFail("boot container volume must not get a rule")
    }
  }

  func testUnknownBootContainerFailsClosedForAPFS() throws {
    let lookup = makeLookup(
      info: [externalUUID: try fixture("diskutilInfoExternalAPFS")],
      apfsList: try fixture("apfsListExternal"))
    guard case .ineligible = lookup.startupBlockEligibility(forVolumeUUID: externalUUID) else {
      return XCTFail("without the boot container an APFS volume must be refused")
    }
  }

  func testRolesLookupFailureIsTreatedAsSystemRole() throws {
    let lookup = makeLookup(
      info: [
        externalUUID: try fixture("diskutilInfoExternalAPFS"),
        "/": try fixture("diskutilInfoBoot"),
      ],
      apfsList: nil)
    XCTAssertEqual(
      lookup.startupBlockEligibility(forVolumeUUID: externalUUID),
      .ineligible("it has a macOS system role"))
  }

  func testExFATVolumeNeedsNoAPFSLookup() throws {
    var calls: [[String]] = []
    let lookup = makeLookup(
      info: [
        exfatUUID: try fixture("diskutilInfoExFAT"),
        "/": try fixture("diskutilInfoBoot"),
      ],
      apfsList: nil, calls: &calls)
    XCTAssertEqual(
      lookup.startupBlockEligibility(forVolumeUUID: exfatUUID),
      .eligible(fileSystemType: "exfat"))
    XCTAssertFalse(calls.contains { $0.starts(with: ["apfs"]) })
  }

  func testDisconnectedVolumeIsNotConnected() {
    let lookup = makeLookup(info: [:], apfsList: nil)
    XCTAssertEqual(lookup.startupBlockEligibility(forVolumeUUID: externalUUID), .notConnected)
  }

  func testBootContainerIsResolvedOncePerLookupObject() throws {
    var calls: [[String]] = []
    let lookup = makeLookup(
      info: [
        exfatUUID: try fixture("diskutilInfoExFAT"),
        "/": try fixture("diskutilInfoBoot"),
      ],
      apfsList: nil, calls: &calls)
    _ = lookup.startupBlockEligibility(forVolumeUUID: exfatUUID)
    _ = lookup.startupBlockEligibility(forVolumeUUID: exfatUUID)
    XCTAssertEqual(calls.filter { $0 == ["info", "-plist", "/"] }.count, 1)
  }
}
