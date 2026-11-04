import DJQCore
import Foundation

/// Where the app's Postiz key and calls come from.
///
/// - The installed app: the Keychain (`KeychainPostizKeyStore`) and the real transport.
/// - `--snapshot` and `DJQ_FAKE_POSTIZ=1` (dev runs against the dev root): an in-memory key and a sample transport
///   that answers `is-connected` and `integrations` from `PostizSamples`, so every Postiz state renders with no key,
///   no Keychain and no network.
@MainActor
enum PostizEnvironment {
  /// Fake in snapshots, with `DJQ_FAKE_POSTIZ=1`, and in every dev run (`DJQ_HOME` or `DJQ_ROOT` set) unless
  /// `DJQ_POSTIZ_LIVE=1` asks for the real thing on purpose. A fake run also turns core's live switch off
  /// (`PostizLive.disabled`), so nothing in the process can reach the Keychain item or Postiz.
  static var isFake: Bool {
    let env = ProcessInfo.processInfo.environment
    if AppModel.isSnapshotRun || env["DJQ_FAKE_POSTIZ"] == "1" { return true }
    if env["DJQ_POSTIZ_LIVE"] == "1" { return false }
    return env["DJQ_HOME"] != nil || env["DJQ_ROOT"] != nil
  }

  static func keyStore() -> PostizKeyStore {
    if isFake { PostizLive.disabled = true }
    if AppModel.isSnapshotRun { return MemoryPostizKeyStore() }  // shots set `postiz.hasKey` themselves
    if isFake { return MemoryPostizKeyStore(key: ProcessInfo.processInfo.environment["DJQ_FAKE_POSTIZ_KEY"] == "0" ? nil : "sample-key") }
    return KeychainPostizKeyStore()
  }

  static func transport(_ store: Store) -> PostizTransport {
    isFake ? SamplePostizTransport() : URLSessionPostizTransport(tempDir: store.paths.work)
  }
}

/// The handful of Postiz operations Settings → Publishing and the post rows need, on the core `PostizService`
/// (shared hourly budget, 429 pause, "key refused" flag — the same rules as the engine and `djq`). The engine
/// running in this process gets the same service, so fake runs never reach the Keychain or Postiz.
final class PostizBridge: @unchecked Sendable {
  let service: PostizService

  init(store: Store, keyStore: PostizKeyStore, transport: PostizTransport) {
    service = PostizService(store: store, transport: transport, keyStore: keyStore)
  }

  func hasKey() -> Bool { service.hasKey() }
  func saveKey(_ k: String) throws { try service.saveKey(k) }
  func deleteKey() throws { try service.deleteKey() }

  /// `GET /is-connected`, then the channel list (cached in kv for the router and the UI). Two budgeted calls.
  func check() throws -> [PostizIntegration] {
    guard try service.checkConnection() else { throw PostizError.unauthorized("not connected") }
    return try service.channels(refresh: true)
  }

  /// Test run: a Postiz draft → scheduled (one budgeted call).
  func releaseDraft(postId: String) throws { try service.releaseDraft(postId: postId) }
}

/// Answers the two read-only calls Settings makes, from sample channels. Anything else is "not found".
final class SamplePostizTransport: PostizTransport, @unchecked Sendable {
  func send(_ r: PostizHTTPRequest) throws -> PostizHTTPResponse {
    let path = r.url.path
    if path.hasSuffix("/is-connected") { return PostizHTTPResponse(status: 200, body: Data(#"{"connected":true}"#.utf8)) }
    if path.hasSuffix("/integrations") {
      let list = PostizSamples.channels.map { c -> [String: Any] in
        ["id": c.id, "name": c.name, "identifier": c.identifier, "disabled": c.disabled, "profile": c.profile ?? ""]
      }
      return PostizHTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8))
    }
    if r.method == "PUT", path.contains("/posts/") { return PostizHTTPResponse(status: 200, body: Data(#"{"state":"QUEUE"}"#.utf8)) }
    return PostizHTTPResponse(status: 404, body: Data(#"{"message":"sample transport"}"#.utf8))
  }
}

/// Made-up channels for snapshots and dev runs (never real ids).
enum PostizSamples {
  static let channels: [PostizIntegration] = [
    PostizIntegration(id: "sample-tt", name: "DJ Lovd", identifier: "tiktok-business", profile: "djlovd"),
    PostizIntegration(id: "sample-ig", name: "djlovd", identifier: "instagram-standalone", profile: "djlovd"),
    PostizIntegration(id: "sample-fb", name: "DJ Lovd Page", identifier: "facebook", profile: "djlovd"),
    PostizIntegration(id: "sample-yt", name: "DJ Lovd", identifier: "youtube", profile: "djlovd"),
    PostizIntegration(id: "sample-th", name: "djlovd", identifier: "threads", disabled: true, profile: "djlovd"),
    PostizIntegration(id: "sample-x", name: "DJLovd", identifier: "x", profile: "djlovd"),
  ]
}
