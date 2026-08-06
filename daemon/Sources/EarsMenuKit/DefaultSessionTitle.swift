import EarsCore
import Foundation

/// The title the menu gives a manually started session. `earsd` names an
/// untitled manual start `session` — it has no meeting identity to work from —
/// which is indistinguishable from every other manual start in the Recent
/// Sessions list, so the menu supplies a dated one instead.
public enum DefaultSessionTitle {
  /// `Recording 2026-08-05 14:03`, in the user's own time zone. The format is
  /// fixed (POSIX locale) so a non-Gregorian regional calendar cannot reword it.
  public static func forManualStart(at instant: Instant, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let date = Date(timeIntervalSince1970: instant.secondsSinceEpoch)
    return "Recording \(formatter.string(from: date))"
  }
}
