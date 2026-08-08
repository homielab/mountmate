//  Created by homielab.com

import SwiftUI

struct PopoverContent<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      content()
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
