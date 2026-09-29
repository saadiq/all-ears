import EarsCore
import Foundation

/// The app's one wall-clock read, kept out of `EarsMenuKit` so the pure core
/// only ever sees injected instants.
enum AppClock {
  static func now() -> Instant { Instant(secondsSinceEpoch: Date().timeIntervalSince1970) }
}
