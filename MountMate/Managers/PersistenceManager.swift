//  Created by homielab.com

import Foundation
import Combine

class PersistenceManager: ObservableObject {
    static let shared = PersistenceManager()

    private let ignoredDisksKey = "mountmate_ignoredDisks"
    private let protectedVolumesKey = "mountmate_protectedVolumes"
    
    @Published var ignoredDisks: [String]
    @Published var protectedVolumes: [String]
    
    private init() {
        self.ignoredDisks = UserDefaults.standard.stringArray(forKey: ignoredDisksKey) ?? []
        self.protectedVolumes = UserDefaults.standard.stringArray(forKey: protectedVolumesKey) ?? []
    }
    
    func ignore(diskID: String) {
        guard !ignoredDisks.contains(diskID) else { return }
        ignoredDisks.append(diskID)
        saveIgnoredDisks()
    }
    
    func unignore(diskID: String) {
        ignoredDisks.removeAll { $0 == diskID }
        saveIgnoredDisks()
    }
    
    func protect(volumeID: String) {
        guard !protectedVolumes.contains(volumeID) else { return }
        protectedVolumes.append(volumeID)
        saveProtectedVolumes()
    }
    
    func unprotect(volumeID: String) {
        protectedVolumes.removeAll { $0 == volumeID }
        saveProtectedVolumes()
    }
    
    private func saveIgnoredDisks() {
        UserDefaults.standard.set(ignoredDisks, forKey: ignoredDisksKey)
    }
    
    private func saveProtectedVolumes() {
        UserDefaults.standard.set(protectedVolumes, forKey: protectedVolumesKey)
    }
}
