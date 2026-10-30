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

  // MARK: Results and state (Get Mounted Volumes, Is Volume Mounted)

  private func mountedAt(
    _ path: String?, id: String, name: String = "Backup", category: DriveCategory = .user
  ) -> Volume {
    Volume(
      id: id, deviceIdentifier: "disk-\(id)", diskUUID: nil, name: name,
      isMounted: path != nil, mountPoint: path, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: category,
      isProtected: false, snapshots: [], storageError: nil)
  }

  func testMountedVolumesListsMountedUserVolumesOfExternalDisksInMenuOrder() {
    let image = disk("disk9", type: .diskImage, volumes: [volume("Installer")])
    let usb = disk(
      "disk4",
      volumes: [
        volume("EFI", category: .system), volume("Photos"), volume("Off", mounted: false),
        volume("Backup"),
      ])
    let builtIn = disk("disk0", type: .internalDisk, volumes: [volume("Macintosh HD")])
    let unverified = disk("disk5", volumes: [volume("Unknown")])
    let mounted = VolumeIntentPlanner.mountedVolumes(
      in: [image, builtIn, usb, unverified], unverifiedDiskIDs: ["disk5"])
    XCTAssertEqual(mounted.map(\.name), ["Photos", "Backup", "Installer"])
    XCTAssertEqual(VolumeIntentPlanner.mountedVolumes(in: [], unverifiedDiskIDs: []), [])
  }

  func testIsMountedAnswersFromTheMountTable() {
    let volumes = [volume("Backup"), volume("Photos", mounted: false)]
    XCTAssertEqual(
      VolumeIntentPlanner.isMounted(.init(name: "backup", volumeUUID: nil), in: volumes),
      .answer(true))
    XCTAssertEqual(
      VolumeIntentPlanner.isMounted(.init(name: "Photos", volumeUUID: nil), in: volumes),
      .answer(false))
  }

  func testIsMountedIsFalseForAVolumeThatIsNotConnected() {
    XCTAssertEqual(
      VolumeIntentPlanner.isMounted(.init(name: "Gone", volumeUUID: uuidA), in: [volume("A")]),
      .answer(false))
  }

  func testIsMountedFailsWhenTwoVolumesCannotBeToldApart() {
    let volumes = [untitled(uuidA, device: "disk4s1"), untitled(uuidB, device: "disk5s1")]
    XCTAssertEqual(
      VolumeIntentPlanner.isMounted(
        .init(name: "Untitled", volumeUUID: nil), in: volumes, localize: { $0 }),
      .failure(
        "More than one volume is named “Untitled”. Choose the volume again in the shortcut."))
    XCTAssertEqual(
      VolumeIntentPlanner.isMounted(.init(name: "Untitled", volumeUUID: uuidB), in: volumes),
      .answer(true))
  }

  func testMountPointIsReadFromTheListAfterTheMount() {
    let before = mountedAt(nil, id: uuidA)
    let after = [mountedAt("/Volumes/Other", id: uuidB), mountedAt("/Volumes/Backup 1", id: uuidA)]
    XCTAssertEqual(VolumeIntentPlanner.mountPoint(of: before, in: after), "/Volumes/Backup 1")
    XCTAssertNil(VolumeIntentPlanner.mountPoint(of: before, in: [mountedAt(nil, id: uuidA)]))
    XCTAssertNil(VolumeIntentPlanner.mountPoint(of: before, in: [mountedAt("  ", id: uuidA)]))
    XCTAssertNil(VolumeIntentPlanner.mountPoint(of: before, in: []))
  }

  func testMountPointFindsTheVolumeByUUIDWhenItsIdentifierChanged() {
    let before = mountedAt(nil, id: uuidA)
    let after = mountedAt("/Users/me/Backup", id: uuidA.lowercased())
    XCTAssertEqual(VolumeIntentPlanner.mountPoint(of: before, in: [after]), "/Users/me/Backup")
  }

  func testMountPlanOfAMountedVolumeKeepsItsMountPoint() {
    let mounted = mountedAt("/Volumes/Backup", id: uuidA)
    guard
      case .alreadyDone(let found) = VolumeIntentPlanner.plan(
        .init(name: "Backup", volumeUUID: uuidA), in: [mounted], mount: true)
    else { return XCTFail("expected alreadyDone") }
    XCTAssertEqual(VolumeIntentPlanner.mountPoint(of: found, in: [mounted]), "/Volumes/Backup")
  }

  // MARK: Same-named volumes (UUID references)

  private let uuidA = "11111111-1111-1111-1111-111111111111"
  private let uuidB = "22222222-2222-2222-2222-222222222222"

  private func untitled(_ uuid: String, device: String, mounted: Bool = true) -> Volume {
    Volume(
      id: uuid, deviceIdentifier: device, diskUUID: nil, name: "Untitled",
      isMounted: mounted, mountPoint: nil, freeSpace: nil, totalSize: nil, usedSpace: nil,
      usedBytes: nil, fileSystemType: nil, usagePercentage: nil, category: .user,
      isProtected: false, snapshots: [], storageError: nil)
  }

  func testTwoSameNamedVolumesAreToldApartByUUID() {
    let first = untitled(uuidA, device: "disk4s1")
    let second = untitled(uuidB, device: "disk5s1", mounted: false)
    let volumes = [first, second]
    XCTAssertEqual(
      VolumeIntentPlanner.match(.init(name: "Untitled", volumeUUID: uuidB), in: volumes),
      .found(second))
    XCTAssertEqual(
      VolumeIntentPlanner.plan(
        .init(name: "Untitled", volumeUUID: uuidB.lowercased()), in: volumes, mount: true),
      .run(second))
    XCTAssertEqual(
      VolumeIntentPlanner.plan(
        .init(name: "Untitled", volumeUUID: uuidA), in: volumes, mount: false),
      .run(first))
  }

  func testEjectPlanPicksTheDiskOfTheVolumeWithThatUUID() {
    let first = disk("disk4", volumes: [untitled(uuidA, device: "disk4s1")])
    let second = disk("disk5", volumes: [untitled(uuidB, device: "disk5s1")])
    XCTAssertEqual(
      VolumeIntentPlanner.ejectPlan(
        .init(name: "Untitled", volumeUUID: uuidB), in: [first, second], unverifiedDiskIDs: []),
      .run(second))
  }

  func testNameOnlyReferenceOfAnOlderShortcutStillMatchesAUniqueName() {
    let volumes = [untitled(uuidA, device: "disk4s1"), volume("Photos")]
    let saved = VolumeIntentPlanner.Reference(identifier: "untitled")
    XCTAssertNil(saved.volumeUUID)
    XCTAssertEqual(VolumeIntentPlanner.match(saved, in: volumes), .found(volumes[0]))
  }

  func testSameNameWithoutUUIDStaysAmbiguous() {
    let volumes = [untitled(uuidA, device: "disk4s1"), untitled(uuidB, device: "disk5s1")]
    XCTAssertEqual(
      VolumeIntentPlanner.match(.init(name: "Untitled", volumeUUID: nil), in: volumes), .ambiguous)
    let noUUID = [volume("Untitled"), volume("Untitled")]
    XCTAssertEqual(
      VolumeIntentPlanner.match(.init(name: "Untitled", volumeUUID: uuidA), in: noUUID), .ambiguous)
  }

  func testUnknownUUIDFallsBackToTheName() {
    let erased = untitled(uuidB, device: "disk4s1")
    XCTAssertEqual(
      VolumeIntentPlanner.match(.init(name: "untitled", volumeUUID: uuidA), in: [erased]),
      .found(erased))
    XCTAssertEqual(
      VolumeIntentPlanner.match(.init(name: "Ghost", volumeUUID: uuidA), in: [erased]), .notFound)
  }

  func testReferenceIdentifierRoundTrips() {
    let withUUID = VolumeIntentPlanner.Reference(name: "My: Disk", volumeUUID: uuidA)
    XCTAssertEqual(withUUID.identifier, "volume-uuid:\(uuidA):My: Disk")
    XCTAssertEqual(VolumeIntentPlanner.Reference(identifier: withUUID.identifier), withUUID)
    let plain = VolumeIntentPlanner.Reference(name: "Backup", volumeUUID: nil)
    XCTAssertEqual(plain.identifier, "Backup")
    XCTAssertEqual(VolumeIntentPlanner.Reference(identifier: "Backup"), plain)
    // Not a valid UUID after the prefix: the whole text is a name.
    XCTAssertEqual(
      VolumeIntentPlanner.Reference(identifier: "volume-uuid:nope"),
      .init(name: "volume-uuid:nope", volumeUUID: nil))
  }

  func testReferenceOfAVolumeWithoutUUIDIsItsName() {
    let reference = VolumeIntentPlanner.Reference(volume: volume("Stick"))
    XCTAssertEqual(reference, .init(name: "Stick", volumeUUID: nil))
    XCTAssertEqual(
      VolumeIntentPlanner.Reference(volume: untitled(uuidA, device: "disk4s1")).volumeUUID, uuidA)
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

  func testEjectPlanRefusesADiskWithAnotherProtectedVolume() {
    let identity: IntentMessages.Localize = { $0 }
    let disks = [disk("disk2", volumes: [volume("Photos"), volume("Backup", isProtected: true)])]
    XCTAssertEqual(
      VolumeIntentPlanner.ejectPlan(
        name: "Photos", in: disks, unverifiedDiskIDs: [], localize: identity),
      .failure(IntentMessages.ejectDiskProtected(name: "Photos", localize: identity)))
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
      .failure("More than one volume is named “Data”. Choose the volume again in the shortcut."))
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
        IntentMessages.volumeNameAmbiguous(name: "X", localize: localize),
        IntentMessages.volumeNameAmbiguous(name: "X", localize: english), language)
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
