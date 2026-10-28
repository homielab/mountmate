//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeIntentPlannerTests: XCTestCase {
  private func volume(
    _ name: String, mounted: Bool = true, isProtected: Bool = false,
    category: DriveCategory = .user
  ) -> Volume {
    Volume(
      id: "id-\(name)", deviceIdentifier: "disk-\(name)", diskUUID: nil, name: name,
      isMounted: mounted, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: category,
      isProtected: isProtected, snapshots: [], storageError: nil)
  }

  private func disk(
    _ id: String, type: PhysicalDiskType = .physical, volumes: [Volume]
  ) -> PhysicalDisk {
    PhysicalDisk(
      id: id, diskUUID: nil, connectionType: "USB", name: id, totalSize: nil, freeSpace: nil,
      usedSpace: nil, usagePercentage: nil, type: type, isRAIDSet: false, partitions: volumes,
      containers: [], storageError: nil)
  }

  func testMatchIgnoresCaseAndSurroundingSpaces() {
    let backup = volume("Time Machine")
    XCTAssertEqual(
      VolumeIntentPlanner.match(name: "  time machine ", in: [volume("Other"), backup]),
      .found(backup))
  }

  func testMatchNotFoundForUnknownOrEmptyName() {
    XCTAssertEqual(VolumeIntentPlanner.match(name: "Nope", in: [volume("A")]), .notFound)
    XCTAssertEqual(VolumeIntentPlanner.match(name: "  ", in: [volume("A")]), .notFound)
  }

  func testExactCaseWinsOverLooseMatch() {
    let upper = volume("DATA")
    let lower = volume("data")
    XCTAssertEqual(VolumeIntentPlanner.match(name: "data", in: [upper, lower]), .found(lower))
    XCTAssertEqual(VolumeIntentPlanner.match(name: "Data", in: [upper, lower]), .ambiguous)
  }

  func testSameNameTwiceIsAmbiguous() {
    let twin = volume("Backup")
    let other = Volume(
      id: "other", deviceIdentifier: "disk-other", diskUUID: nil, name: "Backup",
      isMounted: true, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
    XCTAssertEqual(VolumeIntentPlanner.match(name: "Backup", in: [twin, other]), .ambiguous)
  }

  func testEjectPlanRunsTheDiskHoldingAnExternalVolume() {
    let target = disk("disk2", volumes: [volume("Backup"), volume("Photos")])
    let disks = [disk("disk1", volumes: [volume("Other")]), target]
    XCTAssertEqual(
      VolumeIntentPlanner.ejectPlan(name: "photos", in: disks, unverifiedDiskIDs: []),
      .run(target))
  }

  func testEjectPlanRefusesProtectedInternalAndUnverified() {
    let identity: IntentMessages.Localize = { $0 }
    let disks = [
      disk("disk2", volumes: [volume("Guarded", isProtected: true)]),
      disk("disk3", type: .internalDisk, volumes: [volume("Macintosh HD")]),
      disk("disk4", volumes: [volume("Unknown")]),
    ]
    func plan(_ name: String) -> VolumeIntentPlanner.EjectPlan {
      VolumeIntentPlanner.ejectPlan(
        name: name, in: disks, unverifiedDiskIDs: ["disk4"], localize: identity)
    }
    XCTAssertEqual(
      plan("Guarded"),
      .failure(IntentMessages.volumeProtected(name: "Guarded", localize: identity)))
    XCTAssertEqual(
      plan("Macintosh HD"),
      .failure(IntentMessages.volumeNotFound(name: "Macintosh HD", localize: identity)))
    XCTAssertEqual(
      plan("Unknown"),
      .failure(IntentMessages.ejectUnverified(name: "disk4", localize: identity)))
    XCTAssertEqual(
      plan("Nope"), .failure(IntentMessages.volumeNotFound(name: "Nope", localize: identity)))
  }

  func testEjectPlanOfADiskImageIgnoresUnverifiedState() {
    let image = disk("disk5", type: .diskImage, volumes: [volume("Image")])
    XCTAssertEqual(
      VolumeIntentPlanner.ejectPlan(name: "Image", in: [image], unverifiedDiskIDs: ["disk5"]),
      .run(image))
  }

  func testCandidatesLeaveOutSystemVolumesAndInternalDisks() {
    let disks = [
      disk("disk2", volumes: [volume("A"), volume("EFI", category: .system)]),
      disk("disk3", type: .internalDisk, volumes: [volume("Macintosh HD")]),
      disk("disk4", volumes: [volume("Unverified")]),
    ]
    let names = VolumeIntentPlanner.candidates(in: disks, unverifiedDiskIDs: ["disk4"]).map(\.name)
    XCTAssertEqual(names, ["A"])
  }

  func testMountPlans() {
    let off = volume("Off", mounted: false)
    let on = volume("On")
    XCTAssertEqual(VolumeIntentPlanner.plan(name: "off", in: [off, on], mount: true), .run(off))
    XCTAssertEqual(
      VolumeIntentPlanner.plan(name: "on", in: [off, on], mount: true), .alreadyDone(on))
  }

  func testUnmountPlans() {
    let off = volume("Off", mounted: false)
    let on = volume("On")
    XCTAssertEqual(VolumeIntentPlanner.plan(name: "ON", in: [off, on], mount: false), .run(on))
    XCTAssertEqual(
      VolumeIntentPlanner.plan(name: "off", in: [off, on], mount: false), .alreadyDone(off))
  }

  func testProtectedVolumeIsRefusedForUnmountButCanMount() {
    let protected = volume("Archive", isProtected: true)
    XCTAssertEqual(
      VolumeIntentPlanner.plan(name: "archive", in: [protected], mount: false, localize: { $0 }),
      .failure("“Archive” is protected and cannot be unmounted."))
    let offProtected = volume("Archive", mounted: false, isProtected: true)
    XCTAssertEqual(
      VolumeIntentPlanner.plan(name: "archive", in: [offProtected], mount: true),
      .run(offProtected))
  }

  func testNotFoundAndAmbiguousMessages() {
    XCTAssertEqual(
      VolumeIntentPlanner.plan(name: "Ghost", in: [], mount: true, localize: { $0 }),
      .failure("No volume named “Ghost”."))
    XCTAssertEqual(
      VolumeIntentPlanner.plan(
        name: "Data", in: [volume("DATA"), volume("data")], mount: true, localize: { $0 }),
      .failure("More than one volume is named “Data”."))
  }

  func testShareUnmountMessages() {
    XCTAssertEqual(
      IntentMessages.shareUnmountFailure(name: "NAS", reason: nil, localize: { $0 }),
      "Could not unmount “NAS”.")
    XCTAssertEqual(
      IntentMessages.shareUnmountFailure(name: "NAS", reason: "busy", localize: { $0 }),
      "Could not unmount “NAS”: busy")
    XCTAssertEqual(
      IntentMessages.shareUnmounted(name: "NAS", localize: { $0 }), "“NAS” unmounted.")
  }

  func testNewMessagesAreTranslated() throws {
    let english = try localizer("en")
    for language in ["fr", "ru", "uk", "vi", "zh-Hans", "zh-Hant"] {
      let localize = try localizer(language)
      XCTAssertNotEqual(
        IntentMessages.volumeNotFound(name: "X", localize: localize),
        IntentMessages.volumeNotFound(name: "X", localize: english), language)
      XCTAssertNotEqual(
        IntentMessages.volumeProtected(name: "X", localize: localize),
        IntentMessages.volumeProtected(name: "X", localize: english), language)
      XCTAssertTrue(IntentMessages.shareUnmounted(name: "X", localize: localize).contains("X"))
    }
  }

  private func localizer(_ language: String) throws -> IntentMessages.Localize {
    let path = try XCTUnwrap(
      Bundle(for: DriveManager.self).path(forResource: language, ofType: "lproj"))
    let bundle = try XCTUnwrap(Bundle(path: path))
    return { bundle.localizedString(forKey: $0, value: nil, table: nil) }
  }
}
