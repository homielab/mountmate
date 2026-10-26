//  Created by homielab.com

import Combine
import SwiftUI

/// The "retrying in N s" line under a share or volume that Keep Alive is
/// waiting to reconnect.
enum RetryCountdown: Equatable {
  case seconds(Int)
  case minutes(Int)

  /// Time left until `next`, rounded up so the line never reads "0 seconds"
  /// before the retry; nil when there is no retry scheduled or it is due.
  static func remaining(next: Date?, now: Date) -> RetryCountdown? {
    guard let next else { return nil }
    let left = next.timeIntervalSince(now)
    guard left > 0 else { return nil }
    let seconds = Int(left.rounded(.up))
    if seconds < 60 { return .seconds(seconds) }
    return .minutes(Int((Double(seconds) / 60).rounded(.up)))
  }

  /// "Retrying in 12 seconds"; nil when nothing is scheduled. `bundle` and
  /// `locale` let tests pick a language.
  static func text(
    next: Date?, now: Date, bundle: Bundle = .main, locale: Locale = .current
  ) -> String? {
    switch remaining(next: next, now: now) {
    case .seconds(let n):
      return PluralizedString.format("retry.in.seconds", n, bundle: bundle, locale: locale)
    case .minutes(let n):
      return PluralizedString.format("retry.in.minutes", n, bundle: bundle, locale: locale)
    case nil:
      return nil
    }
  }
}

/// A one-second clock that only runs between `start()` and `stop()`. The
/// countdown view starts it when it appears and stops it when it goes away,
/// so nothing ticks while the popover is closed.
final class CountdownTicker: ObservableObject {
  @Published private(set) var now = Date()
  private var timer: Timer?

  var isRunning: Bool { timer != nil }

  func start() {
    guard timer == nil else { return }
    now = Date()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.now = Date()
    }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  deinit { timer?.invalidate() }
}

/// Status line for a target Keep Alive is reconnecting: the countdown and a
/// "Reconnect Now" button that retries right away.
struct ReconnectStatusLine: View {
  /// Reads the manager's schedule on every tick.
  let nextRetry: () -> Date?
  let reconnectNow: () -> Void
  @StateObject private var ticker = CountdownTicker()

  var body: some View {
    HStack(spacing: 6) {
      if let text = RetryCountdown.text(next: nextRetry(), now: ticker.now) {
        Text(text)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Button("Reconnect Now", action: reconnectNow)
        .buttonStyle(.link)
        .font(.caption)
    }
    .onAppear { ticker.start() }
    .onDisappear { ticker.stop() }
  }
}
