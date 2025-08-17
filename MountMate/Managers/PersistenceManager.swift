//  Created by homielab.com

import Foundation
import Combine

class PersistenceManager: ObservableObject {
    static let shared = PersistenceManager()

    private let protectedVolumesKey = "mountmate_protectedVolumes_v3"
    private let ignoredVolumesKey = "mountmate_ignoredVolumes_v3"
    
    @Published var protectedVolumes: [ManagedVolumeInfo]
    @Published var ignoredVolumes: [ManagedVolumeInfo]
    
    private init() {
        self.protectedVolumes = Self.load(from: protectedVolumesKey)
        self.ignoredVolumes = Self.load(from: ignoredVolumesKey)
    }

    // MARK: - Actions
    
    func protect(volume: Volume) {
        guard let diskUUID = volume.diskUUID else { return }
        let info = ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
        protectedVolumes.append(info)
        saveProtectedVolumes()
    }
    
    func unprotect(info: ManagedVolumeInfo) {
        protectedVolumes.removeAll { $0.id == info.id }
        saveProtectedVolumes()
    }
    
    func ignore(volume: Volume) {
        guard let diskUUID = volume.diskUUID else { return }
        let info = ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
        ignoredVolumes.append(info)
        saveIgnoredVolumes()
    }

    func ignore(disk: PhysicalDisk) {
        let infos = disk.volumes.compactMap { volume -> ManagedVolumeInfo? in
            guard let diskUUID = volume.diskUUID else { return nil }
            return ManagedVolumeInfo(volumeUUID: volume.id, diskUUID: diskUUID, name: volume.name)
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
    
    // MARK: - Helper Checkers
    
    func isVolumeProtected(volumeUUID: String, diskUUID: String) -> Bool {
        protectedVolumes.contains(where: { $0.volumeUUID == volumeUUID && $0.diskUUID == diskUUID })
    }
    
    func isVolumeIgnored(volumeUUID: String, diskUUID: String) -> Bool {
        ignoredVolumes.contains(where: { $0.volumeUUID == volumeUUID && $0.diskUUID == diskUUID })
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
}
