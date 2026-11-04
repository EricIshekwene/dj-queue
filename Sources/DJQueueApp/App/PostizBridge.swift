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
  static var isFake: Bool {
    AppModel.isSnapshotRun || ProcessInfo.processInfo.environment["DJQ_FAKE_POSTIZ"] == "1"
  }

  static func keyStore() -> PostizKeyStore {
    if AppModel.isSnapshotRun { return MemoryPostizKeyStore() }  // shots set `postiz.hasKey` themselves
    if isFake { return MemoryPostizKeyStore(key: ProcessInfo.processInfo.environment["DJQ_FAKE_POSTIZ_KEY"] == "0" ? nil : "sample-key") }
    return KeychainPostizKeyStore()
  }

  static func transport(_ store: Store) -> PostizTransport {
    isFake ? SamplePostizTransport() : URLSessionPostizTransport(tempDir: store.paths.work)
  }
}

/// The handful of Postiz operations Settings → Publishing and the post rows need. Mirrors the core service's key and
/// check rules (shared hourly budget, 429 → 15-minute pause, 401 → "key invalid" flag, success clears it).
// TODO(M2): forward to `PostizService` (saveKey/deleteKey/checkConnection/channels/releaseDraft) once core lands it.
final class PostizBridge: @unchecked Sendable {
  let store: Store
  let keyStore: PostizKeyStore
  let transport: PostizTransport

  init(store: Store, keyStore: PostizKeyStore, transport: PostizTransport) {
    self.store = store
    self.keyStore = keyStore
    self.transport = transport
  }

  func hasKey() -> Bool { keyStore.hasKey() }

  func saveKey(_ k: String) throws {
    try keyStore.save(k)
    try store.clearPostizKeyInvalid()
    try store.logEvent("postiz", "Postiz API key saved")
  }

  func deleteKey() throws {
    try keyStore.delete()
    try store.logEvent("postiz", "Postiz API key removed")
  }

  /// `GET /is-connected`, then the channel list (cached in kv for the router and the UI). Two budgeted calls.
  func check() throws -> [PostizIntegration] {
    let s = try store.settings()
    let ks = keyStore
    let client = PostizClient(transport: transport, base: s.publishing.apiBase) {
      guard let k = try ks.read(), !k.isEmpty else { throw PostizError.noKey }
      return k
    }
    func call<T>(_ body: () throws -> T) throws -> T {
      guard try store.takePostizCall(.check, limit: s.publishing.hourlyBudget) else { throw PostizError.overBudget }
      do {
        let r = try body()
        try store.clearPostizKeyInvalid()
        return r
      } catch PostizError.rateLimited {
        try store.pausePostiz()
        throw PostizError.rateLimited
      } catch PostizError.unauthorized(let m) {
        try store.setPostizKeyInvalid(m.isEmpty ? "Postiz refused the API key" : m)
        throw PostizError.unauthorized(m)
      }
    }
    guard try call({ try client.isConnected() }) else { throw PostizError.unauthorized("not connected") }
    let list = try call { try client.integrations() }
    // Same shape as `PostizChannelCache` (its memberwise init isn't public in M1).
    struct Cache: Encodable { var fetchedAt: Date; var integrations: [PostizIntegration] }
    try store.setKV(PostizChannelCache.kvKey, Cache(fetchedAt: store.clock.now, integrations: list))
    return list
  }

  func releaseDraft(postId: String) throws {
    throw PostizError.badResponse("releasing drafts arrives with the publisher engine")
  }
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
