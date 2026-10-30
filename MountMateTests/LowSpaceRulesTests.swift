//  Created by homielab.com

import XCTest

@testable import MountMate

final class LowSpaceRulesTests: XCTestCase {
  private func volume(
    _ id: String, used: Double?, mounted: Bool = true, readOnly: Bool = false,
    category: DriveCategory = .user, error: String? = nil
  ) -> Volume {
    var volume = Volume(
      id: id, deviceIdentifier: "disk9s\(id)", diskUUID: nil, name: "Vol \(id)",
      isMounted: mounted, mountPoint: mounted ? "/Volumes/\(id)" : nil, freeSpace: "12 GB",
      totalSize: "100 GB", usedSpace: "88 GB", usedBytes: nil, fileSystemType: "apfs",
      usagePercentage: used, category: category, isProtected: false, snapshots: [])
    volume.isReadOnly = readOnly
    volume.storageError = error
    return volume
  }

  private func disk(_ volumes: [Volume], type: PhysicalDiskType = .physical) -> PhysicalDisk {
    PhysicalDisk(
      id: "disk9", diskUUID: nil, connectionType: "USB", name: "Disk", totalSize: nil,
      freeSpace: nil, usedSpace: nil, usagePercentage: nil, type: type, isRAIDSet: false,
      partitions: volumes, containers: [], storageError: nil)
  }

  func testWarnsAtAndAboveTheThresholdOnly() {
    XCTAssertNil(LowSpaceRules.warning(for: volume("1", used: 0.89), on: .physical, threshold: 0.9))
    let atLimit = LowSpaceRules.warning(for: volume("1", used: 0.9), on: .physical, threshold: 0.9)
    XCTAssertEqual(atLimit, LowSpaceRules.Warning(percentUsed: 90, free: "12 GB"))
    XCTAssertEqual(
      LowSpaceRules.warning(for: volume("1", used: 0.94), on: .internalDisk, threshold: 0.9)?
        .percentUsed, 94)
  }

  func testNothingWhenOffOrNotApplicable() {
    let full = volume("1", used: 0.99)
    XCTAssertNil(LowSpaceRules.warning(for: full, on: .physical, threshold: nil))
    XCTAssertNil(LowSpaceRules.warning(for: full, on: .diskImage, threshold: 0.9))
    XCTAssertNil(
      LowSpaceRules.warning(
        for: volume("1", used: 0.99, mounted: false), on: .physical, threshold: 0.9))
    XCTAssertNil(
      LowSpaceRules.warning(
        for: volume("1", used: 0.99, readOnly: true), on: .physical, threshold: 0.9))
    XCTAssertNil(
      LowSpaceRules.warning(
        for: volume("1", used: 0.99, category: .system), on: .physical, threshold: 0.9))
    XCTAssertNil(
      LowSpaceRules.warning(for: volume("1", used: 0.99, error: "x"), on: .physical, threshold: 0.9)
    )
    XCTAssertNil(LowSpaceRules.warning(for: volume("1", used: nil), on: .physical, threshold: 0.9))
  }

  func testSmallVolumesNeverWarn() {
    var bootPartition = volume("1", used: 1)
    bootPartition.totalBytes = 32 * 1_048_576
    XCTAssertNil(LowSpaceRules.warning(for: bootPartition, on: .physical, threshold: 0.9))
    var big = volume("2", used: 0.97)
    big.totalBytes = 64_000_000_000
    XCTAssertEqual(
      LowSpaceRules.warning(for: big, on: .physical, threshold: 0.9)?.percentUsed, 97)
  }

  func testMutedVolumeHasNoBadgeOrNotificationUntilUnmuted() {
    var full = volume("1", used: 0.97)
    full.totalBytes = 64_000_000_000
    full.isLowSpaceMuted = true
    var tracker = LowSpaceAlertTracker()
    XCTAssertNil(LowSpaceRules.warning(for: full, on: .physical, threshold: 0.9))
    XCTAssertTrue(tracker.newWarnings(in: [disk([full])], threshold: 0.9).isEmpty)
    full.isLowSpaceMuted = false
    XCTAssertNotNil(LowSpaceRules.warning(for: full, on: .physical, threshold: 0.9))
    XCTAssertEqual(tracker.newWarnings(in: [disk([full])], threshold: 0.9).map(\.volume.id), ["1"])
  }

  func testPopoverListIsCappedAtSeventyPercentOfTheScreen() {
    XCTAssertEqual(PopoverHeightRules.maxListHeight(visibleFrameHeight: 1000), 700, accuracy: 0.01)
    XCTAssertEqual(PopoverHeightRules.maxListHeight(visibleFrameHeight: nil), 560, accuracy: 0.01)
  }

  func testThresholdReadsTheSettings() {
    let suite = "LowSpaceRulesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(LowSpaceRules.threshold(defaults: defaults), 0.9)
    defaults.set(95, forKey: LowSpaceRules.thresholdKey)
    XCTAssertEqual(LowSpaceRules.threshold(defaults: defaults), 0.95)
    defaults.set(42, forKey: LowSpaceRules.thresholdKey)
    XCTAssertEqual(LowSpaceRules.threshold(defaults: defaults), 0.9)
    defaults.set(false, forKey: LowSpaceRules.enabledKey)
    XCTAssertNil(LowSpaceRules.threshold(defaults: defaults))
    defaults.set(true, forKey: LowSpaceRules.enabledKey)
    XCTAssertEqual(LowSpaceRules.threshold(defaults: defaults), 0.9)
  }

  func testMessageMentionsPercentAndFreeSpace() {
    let message = LowSpaceRules.message(for: .init(percentUsed: 94, free: "12 GB"))
    XCTAssertTrue(message.contains("94"))
    XCTAssertTrue(message.contains("12 GB"))
    XCTAssertTrue(LowSpaceRules.message(for: .init(percentUsed: 94, free: nil)).contains("94"))
  }

  func testTrackerAnnouncesOncePerMountAndAgainAfterRemount() {
    var tracker = LowSpaceAlertTracker()
    let full = [disk([volume("1", used: 0.95), volume("2", used: 0.2)])]
    XCTAssertEqual(tracker.newWarnings(in: full, threshold: 0.9).map(\.volume.id), ["1"])
    XCTAssertTrue(tracker.newWarnings(in: full, threshold: 0.9).isEmpty)
    // Unmounted, then mounted again: announced again.
    let unmounted = [disk([volume("1", used: 0.95, mounted: false)])]
    XCTAssertTrue(tracker.newWarnings(in: unmounted, threshold: 0.9).isEmpty)
    XCTAssertEqual(tracker.newWarnings(in: full, threshold: 0.9).map(\.volume.id), ["1"])
  }

  func testTrackerAnnouncesAgainAfterSpaceWasFreedAndFilledAgain() {
    var tracker = LowSpaceAlertTracker()
    XCTAssertEqual(
      tracker.newWarnings(in: [disk([volume("1", used: 0.95)])], threshold: 0.9).count, 1)
    XCTAssertTrue(tracker.newWarnings(in: [disk([volume("1", used: 0.7)])], threshold: 0.9).isEmpty)
    XCTAssertEqual(
      tracker.newWarnings(in: [disk([volume("1", used: 0.93)])], threshold: 0.9).count, 1)
  }

  func testTrackerAnnouncesOnceWhileHoveringAroundTheThreshold() {
    var tracker = LowSpaceAlertTracker()
    var count = 0
    for used in [0.905, 0.895, 0.905, 0.86, 0.905, 0.895, 0.905] {
      count += tracker.newWarnings(in: [disk([volume("1", used: used)])], threshold: 0.9).count
    }
    XCTAssertEqual(count, 1)
  }

  func testTrackerRearmMarginFollowsTheThreshold() {
    var tracker = LowSpaceAlertTracker()
    XCTAssertEqual(
      tracker.newWarnings(in: [disk([volume("1", used: 0.82)])], threshold: 0.8).count, 1)
    // 76% is above 80 - 5: still remembered.
    XCTAssertTrue(
      tracker.newWarnings(in: [disk([volume("1", used: 0.76)])], threshold: 0.8).isEmpty)
    XCTAssertTrue(
      tracker.newWarnings(in: [disk([volume("1", used: 0.82)])], threshold: 0.8).isEmpty)
    // 75% is forgotten, so filling up again warns again.
    XCTAssertTrue(
      tracker.newWarnings(in: [disk([volume("1", used: 0.75)])], threshold: 0.8).isEmpty)
    XCTAssertEqual(
      tracker.newWarnings(in: [disk([volume("1", used: 0.82)])], threshold: 0.8).count, 1)
    // At 95% the volume must drop to 90%.
    XCTAssertEqual(
      tracker.newWarnings(in: [disk([volume("2", used: 0.97)])], threshold: 0.95).count, 1)
    XCTAssertTrue(
      tracker.newWarnings(in: [disk([volume("2", used: 0.91)])], threshold: 0.95).isEmpty)
    XCTAssertTrue(
      tracker.newWarnings(in: [disk([volume("2", used: 0.96)])], threshold: 0.95).isEmpty)
  }

  func testTrackerStaysQuietWhileTheWarningIsOff() {
    var tracker = LowSpaceAlertTracker()
    let full = [disk([volume("1", used: 0.95)])]
    XCTAssertTrue(tracker.newWarnings(in: full, threshold: nil).isEmpty)
    XCTAssertEqual(tracker.newWarnings(in: full, threshold: 0.9).count, 1)
  }

  func testWarningsListsEveryFullVolume() {
    let disks = [
      disk([volume("1", used: 0.95)]), disk([volume("2", used: 0.99)], type: .diskImage),
    ]
    XCTAssertEqual(LowSpaceRules.warnings(in: disks, threshold: 0.9).count, 1)
  }

  func testWarnsForEveryVolumeOfAFullContainer() {
    // 300 + 100 used of a 500-byte container: 80% for both, though "Data"
    // alone uses 20%.
    let backup = Volume(
      id: "1", deviceIdentifier: "disk9s1", diskUUID: nil, name: "Backup",
      isMounted: true, mountPoint: "/Volumes/Backup", freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: 300, fileSystemType: "apfs", usagePercentage: 0.6,
      category: .user, isProtected: false, snapshots: [])
    let data = Volume(
      id: "2", deviceIdentifier: "disk9s2", diskUUID: nil, name: "Data",
      isMounted: true, mountPoint: "/Volumes/Data", freeSpace: nil, totalSize: nil,
      usedSpace: nil, usedBytes: 100, fileSystemType: "apfs", usagePercentage: 0.2,
      category: .user, isProtected: false, snapshots: [])
    XCTAssertNil(LowSpaceRules.warning(for: data, on: .physical, threshold: 0.8))
    let shared = DiskListParser.apfsContainerUsage(size: 500, volumes: [backup, data])
    for volume in shared {
      XCTAssertEqual(
        LowSpaceRules.warning(for: volume, on: .physical, threshold: 0.8)?.percentUsed, 80)
    }
  }

  // MARK: - Background poll

  private let lastRead = Date(timeIntervalSince1970: 1_000_000)

  private func decision(
    notifications: Bool = true, threshold: Double? = 0.9, disks: [PhysicalDisk]? = nil,
    minutesLater: Double
  ) -> LowSpaceRules.PollDecision {
    LowSpaceRules.pollDecision(
      notificationsEnabled: notifications, threshold: threshold,
      disks: disks ?? [disk([volume("1", used: 0.82)])], lastRead: lastRead,
      now: lastRead.addingTimeInterval(minutesLater * 60))
  }

  func testPollWaitsFifteenMinutesAfterTheLastRead() {
    let due = lastRead.addingTimeInterval(15 * 60)
    XCTAssertEqual(decision(minutesLater: 0), .wait(until: due))
    XCTAssertEqual(decision(minutesLater: 14.9), .wait(until: due))
    XCTAssertEqual(decision(minutesLater: 15), .pollNow)
    XCTAssertEqual(decision(minutesLater: 90), .pollNow)
  }

  func testNoPollWhenNotificationsOrTheWarningAreOff() {
    XCTAssertEqual(decision(notifications: false, minutesLater: 20), .off)
    XCTAssertEqual(decision(threshold: nil, minutesLater: 20), .off)
  }

  func testNoPollWithoutAMountedWritableExternalVolume() {
    XCTAssertEqual(decision(disks: [], minutesLater: 20), .off)
    let notCandidates = [
      disk([volume("1", used: 0.5)], type: .internalDisk),
      disk([volume("2", used: 0.5)], type: .diskImage),
      disk([
        volume("3", used: 0.5, mounted: false), volume("4", used: 0.5, readOnly: true),
        volume("5", used: 0.5, category: .system),
      ]),
    ]
    XCTAssertTrue(LowSpaceRules.pollCandidates(in: notCandidates).isEmpty)
    XCTAssertEqual(decision(disks: notCandidates, minutesLater: 20), .off)
    // A volume whose last read failed is still read again.
    let failed = [disk([volume("6", used: nil, error: "x")])]
    XCTAssertEqual(LowSpaceRules.pollCandidates(in: failed).map(\.id), ["6"])
  }

  func testPolledUsageReplacesOnlyTheReadExternalVolumes() {
    var container = disk([])
    container.containers = [APFSContainer(id: "disk10", volumes: [volume("2", used: 0.5)])]
    let disks = [
      disk([volume("1", used: 0.82), volume("3", used: 0.4, error: "x")]), container,
      disk([volume("4", used: 0.3)], type: .internalDisk),
    ]
    let polled = LowSpaceRules.applyingPolledUsage(
      [
        "/Volumes/1": .usage(total: 1000, free: 40), "/Volumes/2": .usage(total: 1000, free: 50),
        "/Volumes/3": .timedOut, "/Volumes/4": .usage(total: 1000, free: 0),
      ], to: disks)
    let usage = Dictionary(
      uniqueKeysWithValues: polled.flatMap(\.allVolumes).map { ($0.id, $0.usagePercentage) })
    XCTAssertEqual(usage["1"] ?? nil, 0.96)
    XCTAssertEqual(usage["2"] ?? nil, 0.95)
    XCTAssertEqual(usage["3"] ?? nil, 0.4)
    XCTAssertEqual(usage["4"] ?? nil, 0.3)
    XCTAssertEqual(polled[0].partitions[1].storageError, "x")
    XCTAssertEqual(polled[0].partitions[0].freeSpace, ShareUsage.formatted(40))
  }

  func testOvernightFillUpIsAnnouncedOnceByThePoll() {
    var tracker = LowSpaceAlertTracker()
    let at82 = [disk([volume("1", used: 0.82)])]
    XCTAssertTrue(tracker.newWarnings(in: at82, threshold: 0.9).isEmpty)
    // The poll finds 96% later; then each later poll and refresh stay quiet.
    let at96 = LowSpaceRules.applyingPolledUsage(
      ["/Volumes/1": .usage(total: 1000, free: 40)], to: at82)
    XCTAssertEqual(tracker.newWarnings(in: at96, threshold: 0.9).map(\.volume.id), ["1"])
    XCTAssertTrue(tracker.newWarnings(in: at96, threshold: 0.9).isEmpty)
    XCTAssertTrue(
      tracker.newWarnings(in: [disk([volume("1", used: 0.95)])], threshold: 0.9).isEmpty)
  }

  // MARK: - Network shares

  private static let tebibyte: Int64 = 1 << 40

  /// A share of 2 TiB with `used` (fraction) taken.
  private func share(used: Double, total: Int64 = 2 * tebibyte) -> ShareUsage {
    ShareUsage(totalBytes: total, freeBytes: Int64(Double(total) * (1 - used)))
  }

  func testShareWarnsAtAndAboveTheThresholdOnly() {
    XCTAssertNil(LowSpaceRules.warning(for: share(used: 0.896), threshold: 0.95))
    XCTAssertNil(LowSpaceRules.warning(for: share(used: 0.894), threshold: 0.9))
    let full = LowSpaceRules.warning(for: share(used: 0.95), threshold: 0.95)
    XCTAssertEqual(full?.percentUsed, 95)
    XCTAssertEqual(full?.free, ShareUsage.formatted(share(used: 0.95).freeBytes))
    // Like volumes: 89.6% shows as "90%", so it warns at 90.
    XCTAssertEqual(LowSpaceRules.warning(for: share(used: 0.896), threshold: 0.9)?.percentUsed, 90)
  }

  func testReadOnlyShareGetsNoWarning() {
    XCTAssertNil(LowSpaceRules.warning(for: share(used: 0.95), isReadOnly: true, threshold: 0.9))
    XCTAssertNotNil(
      LowSpaceRules.warning(for: share(used: 0.95), isReadOnly: false, threshold: 0.9))
  }

  func testShareWithoutSizeOrWithTheWarningOffGetsNone() {
    XCTAssertNil(LowSpaceRules.warning(for: share(used: 0.99), threshold: nil))
    XCTAssertNil(
      LowSpaceRules.warning(for: ShareUsage(totalBytes: 0, freeBytes: 0), threshold: 0.9))
  }

  func testShareTrackerAnnouncesOnceAndAgainAfterDroppingBelowTheMargin() {
    var tracker = LowSpaceAlertTracker()
    let nas = UUID()
    let other = UUID()
    func announce(_ used: Double, threshold: Double = 0.95) -> [UUID] {
      tracker.newWarnings(
        shareUsage: [nas: share(used: used), other: share(used: 0.2)],
        mountedShareIDs: [nas, other], threshold: threshold
      ).map(\.shareID)
    }
    XCTAssertEqual(announce(0.95), [nas])
    XCTAssertTrue(announce(0.97).isEmpty)
    // 91% is above 95 - 5: still remembered.
    XCTAssertTrue(announce(0.91).isEmpty)
    XCTAssertTrue(announce(0.96).isEmpty)
    // 90% is forgotten, so filling up again warns again.
    XCTAssertTrue(announce(0.9).isEmpty)
    XCTAssertEqual(announce(0.95), [nas])
  }

  func testShareTrackerForgetsUnmountedSharesButNotUnreadOnes() {
    var tracker = LowSpaceAlertTracker()
    let nas = UUID()
    let full = [nas: share(used: 0.96)]
    XCTAssertEqual(
      tracker.newWarnings(shareUsage: full, mountedShareIDs: [nas], threshold: 0.95).count, 1)
    // Mounted, capacity not read this time: still remembered.
    XCTAssertTrue(
      tracker.newWarnings(shareUsage: [:], mountedShareIDs: [nas], threshold: 0.95).isEmpty)
    XCTAssertTrue(
      tracker.newWarnings(shareUsage: full, mountedShareIDs: [nas], threshold: 0.95).isEmpty)
    // Unmounted, then mounted again: announced again.
    XCTAssertTrue(
      tracker.newWarnings(shareUsage: [:], mountedShareIDs: [], threshold: 0.95).isEmpty)
    XCTAssertEqual(
      tracker.newWarnings(shareUsage: full, mountedShareIDs: [nas], threshold: 0.95).count, 1)
  }

  func testShareTrackerIgnoresSharesThatAreNotMountedOrHaveNoSize() {
    var tracker = LowSpaceAlertTracker()
    let stale = UUID()
    let empty = UUID()
    XCTAssertTrue(
      tracker.newWarnings(
        shareUsage: [stale: share(used: 0.99), empty: ShareUsage(totalBytes: 0, freeBytes: 0)],
        mountedShareIDs: [empty], threshold: 0.9
      ).isEmpty)
  }
}
