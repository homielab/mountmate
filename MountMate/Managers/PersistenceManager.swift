//  Created by homielab.com

import Foundation
import Combine

class PersistenceManager: ObservableObject {
    static let shared = PersistenceManager()

    private let protectedVolumesKey = "mountmate_protectedVolumes_v2"
    private let ignoredVolumesKey = "mountmate_ignoredVolumes_v2"
    
    @Published var protectedVolumes: [ManagedVolumeInfo]
    @Published var ignoredVolumes: [ManagedVolumeInfo]
    
    private init() {
        if let data = UserDefaults.standard.data(forKey: protectedVolumesKey) {
            self.protectedVolumes = (try? JSONDecoder().decode([ManagedVolumeInfo].self, from: data)) ?? []
        } else {
            self.protectedVolumes = []
        }
        
        if let data = UserDefaults.standard.data(forKey: ignoredVolumesKey) {
            self.ignoredVolumes = (try? JSONDecoder().decode([ManagedVolumeInfo].self, from: data)) ?? []
        } else {
            self.ignoredVolumes = []
        }
    }
    
    func protect(volume: Volume) {
        guard !isProtected(volumeUUID: volume.id) else { return }
        let info = ManagedVolumeInfo(id: volume.id, name: volume.name)
        protectedVolumes.append(info)
        saveProtectedVolumes()
    }
    
    func unprotect(volumeUUID: String) {
        protectedVolumes.removeAll { $0.id == volumeUUID }
        saveProtectedVolumes()
    }
    
    func ignore(volume: Volume) {
        guard !isIgnored(volumeUUID: volume.id) else { return }
        let info = ManagedVolumeInfo(id: volume.id, name: volume.name)
        ignoredVolumes.append(info)
        saveIgnoredVolumes()
    }
    
    func ignore(volumes: [Volume]) {
        for volume in volumes {
            if !isIgnored(volumeUUID: volume.id) {
                let info = ManagedVolumeInfo(id: volume.id, name: volume.name)
                ignoredVolumes.append(info)
            }
        }
        saveIgnoredVolumes()
    }
    
    func unignore(volumeUUID: String) {
        ignoredVolumes.removeAll { $0.id == volumeUUID }
        saveIgnoredVolumes()
    }
    
    // MARK: - Helper Checkers
    
    func isProtected(volumeUUID: String) -> Bool {
        protectedVolumes.contains { $0.id == volumeUUID }
    }
    
    func isIgnored(volumeUUID: String) -> Bool {
        ignoredVolumes.contains { $0.id == volumeUUID }
    }
    
    // MARK: - Private Save Methods
    
    private func saveProtectedVolumes() {
        if let data = try? JSONEncoder().encode(protectedVolumes) {
            UserDefaults.standard.set(data, forKey: protectedVolumesKey)
        }
    }
    
    private func saveIgnoredVolumes() {
        if let data = try? JSONEncoder().encode(ignoredVolumes) {
            UserDefaults.standard.set(data, forKey: ignoredVolumesKey)
        }
    }
}
