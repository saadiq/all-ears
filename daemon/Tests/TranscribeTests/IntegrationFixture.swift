import CryptoKit
import Foundation

/// Downloads and caches a pinned remote audio fixture for the opt-in, real-model
/// integration suites (``LibriSpeechASRLiveTests``, ``AMIDiarizationLiveTests``).
///
/// These suites touch the network *and* real Core ML/ANE hardware, so — like
/// ``ParakeetLiveModelTests`` — they are off unless `EARS_LIVE_MODEL_TEST=1`.
/// Fixtures are **not** committed (the repo keeps no binaries over ~100 KB and
/// has no Git LFS); each is fetched on demand from a stable public URL and
/// verified against a pinned SHA-256, then cached under
/// `~/Library/Caches` so repeated runs download it only once. A hash mismatch
/// fails loudly rather than silently testing the wrong audio.
enum IntegrationFixture {
  /// The shared opt-in gate: real ANE inference + an internet download.
  static var liveEnabled: Bool {
    ProcessInfo.processInfo.environment["EARS_LIVE_MODEL_TEST"] == "1"
  }

  /// Persistent per-user cache directory for downloaded fixtures.
  static var cacheDirectory: URL {
    let base =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("net.tomelliot.ears.test-fixtures", isDirectory: true)
  }

  enum FixtureError: Error, CustomStringConvertible {
    case checksumMismatch(fileName: String, expected: String, actual: String)

    var description: String {
      switch self {
      case .checksumMismatch(let fileName, let expected, let actual):
        return
          "fixture \(fileName) SHA-256 mismatch: expected \(expected), got \(actual) "
          + "(the remote file changed, or the download was corrupted)"
      }
    }
  }

  /// Returns a local URL to `fileName`, using the cached copy when its SHA-256
  /// already matches, otherwise downloading `url` and verifying it before
  /// caching. Throws ``FixtureError/checksumMismatch`` if the fetched bytes do
  /// not match `sha256`.
  static func fetch(_ url: URL, fileName: String, sha256: String) async throws -> URL {
    let directory = cacheDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(fileName)

    if let cached = try? Data(contentsOf: destination), hexSHA256(cached) == sha256 {
      return destination
    }

    let (temporaryURL, _) = try await URLSession.shared.download(from: url)
    let data = try Data(contentsOf: temporaryURL)
    let actual = hexSHA256(data)
    guard actual == sha256 else {
      throw FixtureError.checksumMismatch(fileName: fileName, expected: sha256, actual: actual)
    }
    try data.write(to: destination, options: .atomic)
    return destination
  }

  /// Lowercase hex SHA-256 of `data`.
  static func hexSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
