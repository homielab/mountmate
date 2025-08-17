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
        guard !isVolumeProtected(id: volume.id) else { return }
        let info = ManagedVolumeInfo(id: volume.id, name: volume.name)
        protectedVolumes.append(info)
        saveProtectedVolumes()
    }
    
    func unprotectVolume(id: String) {
        protectedVolumes.removeAll { $0.id == id }
        saveProtectedVolumes()
    }
    
    func ignore(volume: Volume) {
        guard !isVolumeIgnored(id: volume.id) else { return }
        let info = ManagedVolumeInfo(id: volume.id, name: volume.name)
        ignoredVolumes.append(info)
        saveIgnoredVolumes()
    }
    
    func ignore(volumes: [Volume]) {
        for volume in volumes {
            if !isVolumeIgnored(id: volume.id) {
                let info = ManagedVolumeInfo(id: volume.id, name: volume.name)
                ignoredVolumes.append(info)
            }
        }
        saveIgnoredVolumes()
    }
    
    func unignoreVolume(id: String) {
        ignoredVolumes.removeAll { $0.id == id }
        saveIgnoredVolumes()
    }
    
    // MARK: - Helper Checkers
    
    func isVolumeProtected(id: String) -> Bool {
        protectedVolumes.contains { $0.id == id }
    }
    
    func isVolumeIgnored(id: String) -> Bool {
        ignoredVolumes.contains { $0.id == id }
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
