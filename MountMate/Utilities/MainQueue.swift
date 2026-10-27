//  Created by homielab.com

import Foundation

/// Hops from background work (including async code) to the main thread
/// without ever blocking the caller's thread (never a synchronous dispatch).
///
/// The managers that use it are not `Sendable` yet: the closures passed here
/// may only touch state that is otherwise used on the main thread.
enum MainQueue {
  /// Runs `body` on the main thread later; returns immediately.
  static func perform(_ body: @escaping () -> Void) {
    DispatchQueue.main.async(execute: body)
  }

  /// Runs `body` on the main thread and returns its result. The calling
  /// task is suspended meanwhile; no thread waits.
  static func value<T>(_ body: @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
      perform { continuation.resume(returning: body()) }
    }
  }
}
