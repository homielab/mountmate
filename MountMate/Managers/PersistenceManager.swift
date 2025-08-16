//  Created by homielab.com

import Foundation
import Combine

class PersistenceManager: ObservableObject {
    static let shared = PersistenceManager()

    private let ignoredDisksKey = "mountmate_ignoredDisks"
    private let ignoredVolumesKey = "mountmate_ignoredVolumes"
    private let protectedVolumesKey = "mountmate_protectedVolumes"
    
    @Published var ignoredDisks: [String]
    @Published var ignoredVolumes: [String]
    @Published var protectedVolumes: [String]
    
    private init() {
        self.ignoredDisks = UserDefaults.standard.stringArray(forKey: ignoredDisksKey) ?? []
        self.ignoredVolumes = UserDefaults.standard.stringArray(forKey: ignoredVolumesKey) ?? []
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

    func ignore(volumeID: String) {
        guard !ignoredVolumes.contains(volumeID) else { return }
        ignoredVolumes.append(volumeID)
        saveIgnoredVolumes()
    }
    
    func unignore(volumeID: String) {
        ignoredVolumes.removeAll { $0 == volumeID }
        saveIgnoredVolumes()
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

    private func saveIgnoredVolumes() {
        UserDefaults.standard.set(ignoredVolumes, forKey: ignoredVolumesKey)
    }
    
    private func saveProtectedVolumes() {
        UserDefaults.standard.set(protectedVolumes, forKey: protectedVolumesKey)
    }
}
