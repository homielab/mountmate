//  Created by homielab.com

import XCTest

@testable import MountMate

final class OpenAfterMountRulesTests: XCTestCase {
  private func volume(
    _ id: String, mounted: Bool = true, mountPoint: String? = nil, readOnly: Bool = false,
    protected: Bool = false
  ) -> Volume {
    var volume = Volume(
      id: id, deviceIdentifier: "disk9s\(id)", diskUUID: nil, name: "Vol \(id)",
      isMounted: mounted, mountPoint: mounted ? (mountPoint ?? "/Volumes/\(id)") : nil,
      freeSpace: nil, totalSize: nil, usedSpace: nil, usedBytes: nil, fileSystemType: "apfs",
      usagePercentage: nil, category: .user, isProtected: protected, snapshots: [])
    volume.isReadOnly = readOnly
    return volume
  }

  private func shouldOpen(
    _ trigger: MountTrigger, enabled: Bool = true, succeeded: Bool = true, blocked: Bool = false,
    mountPoint: String? = "/Volumes/Data"
  ) -> Bool {
    OpenAfterMountRules.shouldOpen(
      trigger: trigger, isEnabled: enabled, succeeded: succeeded, isBlocked: blocked,
      mountPoint: mountPoint)
  }

  func testOnlyUserRequestedTriggersOpen() {
    let opening = MountTrigger.allCases.filter { shouldOpen($0) }
    XCTAssertEqual(opening, [.popover, .mountAll, .shortcuts])
    XCTAssertFalse(shouldOpen(.keepAlive))
    XCTAssertFalse(shouldOpen(.wake))
    XCTAssertFalse(shouldOpen(.automatic))
  }

  func testSwitchOffNeverOpens() {
    for trigger in MountTrigger.allCases {
      XCTAssertFalse(shouldOpen(trigger, enabled: false), "\(trigger)")
    }
  }

  func testFailedBlockedOrUnknownMountDoesNotOpen() {
    XCTAssertFalse(shouldOpen(.popover, succeeded: false))
    XCTAssertFalse(shouldOpen(.popover, blocked: true))
    XCTAssertFalse(shouldOpen(.popover, mountPoint: nil))
    XCTAssertFalse(shouldOpen(.shortcuts, mountPoint: ""))
  }

  func testSwitchIsOffByDefault() throws {
    let suite = "OpenAfterMountRulesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertFalse(OpenAfterMountRules.isEnabled(defaults: defaults))
    defaults.set(true, forKey: OpenAfterMountRules.enabledKey)
    XCTAssertTrue(OpenAfterMountRules.isEnabled(defaults: defaults))
  }

  func testMountPointsOpenEachMountedVolumeOnce() {
    let volumes = [
      volume("a"),
      volume("b", mounted: false),
      volume("c", mountPoint: "/Users/me/Backup"),
      volume("d", readOnly: true, protected: true),
    ]
    let paths = OpenAfterMountRules.mountPoints(
      afterMounting: ["c", "a", "b", "a", "missing", "d"], in: volumes, trigger: .mountAll,
      isEnabled: true, isBlocked: { _ in false })
    XCTAssertEqual(paths, ["/Users/me/Backup", "/Volumes/a", "/Volumes/d"])
  }

  func testMountPointsSkipBlockedVolumesAndAutomaticTriggers() {
    let volumes = [volume("a"), volume("b")]
    XCTAssertEqual(
      OpenAfterMountRules.mountPoints(
        afterMounting: ["a", "b"], in: volumes, trigger: .popover, isEnabled: true,
        isBlocked: { $0.id == "b" }),
      ["/Volumes/a"])
    for trigger in [MountTrigger.keepAlive, .wake, .automatic] {
      XCTAssertEqual(
        OpenAfterMountRules.mountPoints(
          afterMounting: ["a"], in: volumes, trigger: trigger, isEnabled: true,
          isBlocked: { _ in false }),
        [], "\(trigger)")
    }
    XCTAssertEqual(
      OpenAfterMountRules.mountPoints(
        afterMounting: ["a"], in: volumes, trigger: .popover, isEnabled: false,
        isBlocked: { _ in false }),
      [])
  }

  func testOpenPassesDirectoryURLsToTheOpener() {
    var opened: [URL] = []
    OpenAfterMountRules.open(["/Volumes/a", "/Users/me/Backup"]) { opened.append($0) }
    XCTAssertEqual(opened.map(\.path), ["/Volumes/a", "/Users/me/Backup"])
    XCTAssertTrue(opened.allSatisfy(\.hasDirectoryPath))
  }
}
