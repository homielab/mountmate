//  Created by homielab.com

import SwiftUI

struct DisplaySettingsSection: View {
  @AppStorage("showInternalDisks") private var showInternalDisks = false
  @AppStorage("showOnlyVolumes") private var showOnlyVolumes = false
  @AppStorage("hideEFIPartitions") private var hideEFIPartitions = false
  @AppStorage("showCountInMenuBar") private var showCountInMenuBar = false

  var body: some View {
    Section {
      Toggle(isOn: $showCountInMenuBar) {
        Label("Show Count in Menu Bar", systemImage: "number.square")
      }
      Toggle(isOn: $showInternalDisks) {
        Label("Show Internal Disks", systemImage: "internaldrive")
      }
      Toggle(isOn: $showOnlyVolumes) {
        Label("Show Only Volumes", systemImage: "externaldrive")
      }
      Toggle(isOn: $hideEFIPartitions) {
        Label("Hide EFI Partitions", systemImage: "eye.slash")
      }
    } header: {
      Label("Display", systemImage: "macwindow")
    }
  }
}
