public enum ReconnectBackoff {
  public static func delay(attempt: Int) -> Duration {
    let clamped = min(max(attempt, 0), 3)
    let seconds = attempt > 3 ? 15 : 1 << clamped
    return .seconds(seconds)
  }
}
