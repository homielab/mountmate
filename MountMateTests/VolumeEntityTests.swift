//  Created by homielab.com

import XCTest

@testable import MountMate

final class VolumeEntityTests: XCTestCase {
  private let uuidA = "11111111-1111-1111-1111-111111111111"
  private let uuidB = "22222222-2222-2222-2222-222222222222"

  private func volume(
    _ name: String, id: String, device: String, size: String? = "16 GB",
    mountPoint: String? = nil
  ) -> Volume {
    Volume(
      id: id, deviceIdentifier: device, diskUUID: nil, name: name,
      isMounted: mountPoint != nil, mountPoint: mountPoint, freeSpace: nil, totalSize: size,
      usedSpace: nil, usedBytes: nil, fileSystemType: nil, usagePercentage: nil,
      category: .user, isProtected: false, snapshots: [], storageError: nil)
  }

  func testSameNamedVolumesAreSuggestedApartWithSubtitles() {
    let mounted = volume(
      "Untitled", id: uuidA, device: "disk4s1", mountPoint: "/Volumes/Untitled")
    let unmounted = volume("Untitled", id: uuidB, device: "disk5s1", size: "64 GB")
    let suggestions = VolumeQuery.suggestions(
      from: [unmounted, volume("Photos", id: "disk6s1", device: "disk6s1"), mounted])

    XCTAssertEqual(suggestions.count, 3)
    XCTAssertEqual(suggestions.map(\.name), ["Photos", "Untitled", "Untitled"])
    XCTAssertEqual(
      suggestions.map(\.subtitle),
      ["16 GB · disk6s1", "16 GB · disk4s1 · /Volumes/Untitled", "64 GB · disk5s1"])
    XCTAssertEqual(Set(suggestions.map(\.id)).count, 3)
    XCTAssertEqual(suggestions[2].reference.volumeUUID, uuidB)
  }

  func testSameNamedVolumesWithoutUUIDCollapseIntoOneEntry() {
    let suggestions = VolumeQuery.suggestions(from: [
      volume("Stick", id: "disk4s1", device: "disk4s1"),
      volume("Stick", id: "disk5s1", device: "disk5s1"),
    ])
    XCTAssertEqual(suggestions.map(\.id), ["Stick"])
  }

  func testEntityCarriesTheMountState() {
    let mounted = VolumeEntity(
      volume: volume("Backup", id: uuidA, device: "disk4s1", mountPoint: "/Volumes/Backup"))
    XCTAssertTrue(mounted.isMounted)
    XCTAssertEqual(mounted.mountPoint, "/Volumes/Backup")
    let unmounted = VolumeEntity(volume: volume("Photos", id: uuidB, device: "disk5s1"))
    XCTAssertFalse(unmounted.isMounted)
    XCTAssertNil(unmounted.mountPoint)
    let unplugged = VolumeQuery.entities(for: ["Old Name"], current: [])
    XCTAssertEqual(unplugged.map(\.isMounted), [false])
  }

  func testShareEntitiesFollowTheMountTable() {
    let nas = NetworkShare(
      name: "NAS", server: "nas.local", sharePath: "/media", username: "",
      mountAtLogin: false, keepMounted: false, shareProtocol: .smb)
    let photos = NetworkShare(
      name: "Photos", server: "nas.local", sharePath: "/photos", username: "",
      mountAtLogin: false, keepMounted: false, shareProtocol: .smb)
    let entities = NetworkShareEntity.entities(
      for: [nas, photos], mountPoints: [photos.id: "/Users/me/mountmate/Photos"])
    XCTAssertEqual(entities.map(\.name), ["NAS", "Photos"])
    XCTAssertEqual(entities.map(\.isMounted), [false, true])
    XCTAssertEqual(entities.map(\.mountPoint), [nil, "/Users/me/mountmate/Photos"])
    XCTAssertFalse(NetworkShareEntity(share: nas, mountPoint: " ").isMounted)
  }

  func testSubtitleLeavesOutUnknownParts() {
    XCTAssertEqual(
      VolumeEntity.subtitle(for: volume("A", id: uuidA, device: "disk4s1", size: nil)), "disk4s1")
  }

  func testEntitiesForSavedIdentifiers() {
    let connected = volume("Untitled", id: uuidA, device: "disk4s1")
    let saved = VolumeIntentPlanner.Reference(name: "Untitled", volumeUUID: uuidA).identifier
    let unplugged = VolumeIntentPlanner.Reference(name: "Untitled", volumeUUID: uuidB).identifier
    let entities = VolumeQuery.entities(
      for: [saved, unplugged, "Old Name"], current: [connected])

    XCTAssertEqual(entities.map(\.id), [saved, unplugged, "Old Name"])
    XCTAssertEqual(entities.map(\.name), ["Untitled", "Untitled", "Old Name"])
    XCTAssertEqual(entities.map(\.subtitle), ["16 GB · disk4s1", nil, nil])
  }
}
