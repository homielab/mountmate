//  Created by homielab.com

import AppKit
import SwiftUI

struct HostingWindowReader: NSViewRepresentable {
  let onResolve: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      onResolve(view.window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      onResolve(nsView.window)
    }
  }
}
