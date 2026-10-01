import Foundation

/// Where a "Summary ready" click lands: the file the daemon reported
/// writing, while it is still there. `nil` sends the caller to its scan —
/// the file may have been moved or renamed since.
public enum SummaryTarget {
  public static func written(_ path: String?, exists: (String) -> Bool) -> URL? {
    guard let path, exists(path) else { return nil }
    return URL(fileURLWithPath: path)
  }
}
