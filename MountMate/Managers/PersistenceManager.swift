//  Created by homielab.com

import Combine
import Foundation

class PersistenceManager: ObservableObject {
  static let shared = PersistenceManager()

  private let protectedVolumesKey = "mountmate_protectedVolumes_v4"
  private let ignoredVolumesKey = "mountmate_ignoredVolumes_v4"
  private let blockedVolumesKey = "mountmate_blockedVolumes_v1"
  private let networkSharesKey = "mountmate_networkShares_v1"

  @Published var protectedVolumes: [ManagedVolumeInfo]
  @Published var ignoredVolumes: [ManagedVolumeInfo]
  @Published var blockedVolumes: [ManagedVolumeInfo]
  @Published var networkShares: [NetworkShare]

  private init() {
    self.protectedVolumes = Self.load(from: protectedVolumesKey)
    self.ignoredVolumes = Self.load(from: ignoredVolumesKey)
    self.blockedVolumes = Self.load(from: blockedVolumesKey)
    self.networkShares = Self.load(from: networkSharesKey)
  }

  // MARK: - Actions

  @discardableResult
  func protect(volume: Volume) -> Bool {
    guard let diskUUID = volume.diskUUID else { return false }
    let info = ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
    guard !protectedVolumes.contains(where: { $0.id == info.id }) else { return true }
    protectedVolumes.append(info)
    saveProtectedVolumes()
    return true
  }

  func unprotect(info: ManagedVolumeInfo) {
    protectedVolumes.removeAll { $0.id == info.id }
    saveProtectedVolumes()
  }

  @discardableResult
  func ignore(volume: Volume) -> Bool {
    guard let diskUUID = volume.diskUUID else { return false }
    let info = ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
    guard !ignoredVolumes.contains(where: { $0.id == info.id }) else { return true }
    ignoredVolumes.append(info)
    saveIgnoredVolumes()
    return true
  }

  func ignore(disk: PhysicalDisk) {
    let infos =
      disk.partitions.compactMap { volume -> ManagedVolumeInfo? in
        guard let diskUUID = volume.diskUUID else { return nil }
        return ManagedVolumeInfo(
          volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
      }
      + disk.containers.flatMap { $0.volumes }.compactMap { volume -> ManagedVolumeInfo? in
        guard let diskUUID = volume.diskUUID else { return nil }
        return ManagedVolumeInfo(
          volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
      }

    for info in infos {
      if !ignoredVolumes.contains(where: { $0.id == info.id }) {
        ignoredVolumes.append(info)
      }
    }
    saveIgnoredVolumes()
  }

  func unignore(info: ManagedVolumeInfo) {
    ignoredVolumes.removeAll { $0.id == info.id }
    saveIgnoredVolumes()
  }

  @discardableResult
  func block(volume: Volume) -> Bool {
    guard let diskUUID = volume.diskUUID else { return false }
    let info = ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
    guard !blockedVolumes.contains(where: { $0.id == info.id }) else { return true }
    blockedVolumes.append(info)
    saveBlockedVolumes()
    return true
  }

  func unblock(info: ManagedVolumeInfo) {
    blockedVolumes.removeAll { $0.id == info.id }
    saveBlockedVolumes()
  }

  func addNetworkShare(_ share: NetworkShare) {
    networkShares.append(share)
    saveNetworkShares()
  }

  func updateNetworkShare(_ share: NetworkShare) {
    if let index = networkShares.firstIndex(where: { $0.id == share.id }) {
      networkShares[index] = share
      saveNetworkShares()
    }
  }

  func removeNetworkShare(_ share: NetworkShare) {
    networkShares.removeAll { $0.id == share.id }
    KeychainManager.shared.delete(account: share.id.uuidString)
    saveNetworkShares()
  }

  // MARK: - Helper Checkers

  func isVolumeProtected(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return protectedVolumes.contains { $0.id == compositeId }
  }

  func isVolumeIgnored(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return ignoredVolumes.contains { $0.id == compositeId }
  }

  func isVolumeBlocked(_ volume: Volume) -> Bool {
    guard let compositeId = volume.compositeId else { return false }
    return blockedVolumes.contains { $0.id == compositeId }
  }

  // MARK: - Private Save/Load Helpers

  private func save<T: Codable>(_ items: [T], to key: String) {
    if let data = try? JSONEncoder().encode(items) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }
  private static func load<T: Codable>(from key: String) -> [T] {
    if let data = UserDefaults.standard.data(forKey: key) {
      return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
    return []
  }

  private func saveProtectedVolumes() { save(protectedVolumes, to: protectedVolumesKey) }
  private func saveIgnoredVolumes() { save(ignoredVolumes, to: ignoredVolumesKey) }
  private func saveBlockedVolumes() { save(blockedVolumes, to: blockedVolumesKey) }
  private func saveNetworkShares() { save(networkShares, to: networkSharesKey) }

}
