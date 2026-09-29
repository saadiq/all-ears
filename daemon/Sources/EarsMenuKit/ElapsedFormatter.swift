/// The menu's running-session clock. Coarser durations are
/// ``EarsCore/HumanUnits/duration(seconds:)``'s — the units `ears status`
/// speaks — so the two surfaces never describe one daemon two ways.
public enum ElapsedFormatter {
  public static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
  }
}
