//  Created by homielab.com

import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gear") }

      ManagementSettingsView()
        .tabItem { Label("Management", systemImage: "slider.horizontal.3") }

      NetworkSharesSettingsView()
        .tabItem { Label("Network Shares", systemImage: "server.rack") }
    }
    .frame(
      minWidth: 420, idealWidth: 420, maxWidth: 450, minHeight: 520, idealHeight: 650,
      maxHeight: 800)
  }
}
