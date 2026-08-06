public enum ElapsedFormatter {
  public static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
  }

  public static func compactDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total)s" }
    if total < 3_600 { return "\(total / 60)m" }
    if total < 86_400 { return "\(total / 3_600)h \((total % 3_600) / 60)m" }
    return "\(total / 86_400)d \((total % 86_400) / 3_600)h"
  }
}
