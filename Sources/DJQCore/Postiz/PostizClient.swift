import Foundation

// The Postiz public API (docs/postiz.md §2). Synchronous, for the engine queue and the CLI. Every request goes
// through an injectable `PostizTransport`; tests use a fake and never touch the network.

// MARK: Transport

public struct PostizHTTPRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public enum Body: Sendable {
    case none
    case json(Data)
    /// multipart/form-data: the file is streamed from disk (never read into memory), plus plain text fields.
    case multipart(file: URL, fileName: String, mimeType: String, fields: [String: String])
  }
  public var method: String
  public var url: URL
  public var headers: [String: String]
  public var body: Body
  public var timeout: TimeInterval

  public init(method: String, url: URL, headers: [String: String], body: Body = .none, timeout: TimeInterval) {
    self.method = method; self.url = url; self.headers = headers; self.body = body; self.timeout = timeout
  }

  /// Every way of printing a request (`"\(req)"`, `debugPrint`, `dump`, the debugger) shows it redacted.
  public var description: String { redactedDescription }
  public var debugDescription: String { redactedDescription }
  public var customMirror: Mirror { Mirror(self, children: ["request": redactedDescription], displayStyle: .struct) }

  /// For logs and errors: method, URL and headers with `Authorization` redacted.
  public var redactedDescription: String {
    let h = headers.keys.sorted().map { k in "\(k): \(k.lowercased() == "authorization" ? "<redacted>" : headers[k]!)" }
    return "\(method) \(url.absoluteString) [\(h.joined(separator: ", "))]"
  }
}

public struct PostizHTTPResponse: Sendable {
  public var status: Int
  public var body: Data
  public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol PostizTransport: AnyObject, Sendable {
  /// Sends one request. Throws only for transport failures (no response); HTTP errors come back as a status.
  func send(_ request: PostizHTTPRequest) throws -> PostizHTTPResponse
}

/// Turns every live Postiz call off for this process. `URLSessionPostizTransport` then fails with `.network` and
/// `KeychainPostizKeyStore` reports no key without running anything. Off when:
/// - `DJQ_POSTIZ_OFFLINE=1`, or
/// - the process runs against a scratch home or root (`DJQ_HOME` / `DJQ_ROOT` set: dev runs, the auto-update gate,
///   `djq` in a dev root) unless `DJQ_POSTIZ_LIVE=1` says so explicitly — a dev run never reads Eric's Keychain item
///   or reaches Postiz by accident;
/// - tests set it (the fixture).
public enum PostizLive {
  nonisolated(unsafe) public static var disabled: Bool = offByEnvironment(ProcessInfo.processInfo.environment)

  public static func offByEnvironment(_ env: [String: String]) -> Bool {
    if env["DJQ_POSTIZ_OFFLINE"] == "1" { return true }
    // Set at all (even empty) = a scratch home, exactly as `Paths.standard` reads it.
    let scratch = env["DJQ_HOME"] != nil || env["DJQ_ROOT"] != nil
    return scratch && env["DJQ_POSTIZ_LIVE"] != "1"
  }
}

/// The real transport: URLSession, blocking the calling (engine/CLI) thread until the response or the timeout.
public final class URLSessionPostizTransport: PostizTransport, @unchecked Sendable {
  let session: URLSession
  let tempDir: URL

  public init(tempDir: URL = FileManager.default.temporaryDirectory) {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    self.tempDir = tempDir
    Multipart.sweep(tempDir)
  }

  /// Redirects are never followed: the key would travel along to wherever they point.
  final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
      completionHandler(nil)
    }
  }

  public func send(_ request: PostizHTTPRequest) throws -> PostizHTTPResponse {
    guard !PostizLive.disabled else { throw PostizError.network("Postiz calls are turned off in this process") }
    guard request.url.scheme?.lowercased() == "https" else { throw PostizError.network("Postiz address must start with https://") }
    var r = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
    r.httpMethod = request.method
    for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
    var upload: URL?
    defer { if let upload { try? FileManager.default.removeItem(at: upload) } }
    switch request.body {
    case .none: break
    case .json(let d):
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
      r.httpBody = d
    case .multipart(let file, let name, let mime, let fields):
      let boundary = "djq-\(UUID().uuidString)"
      r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      upload = try Multipart.write(file: file, fileName: name, mimeType: mime, fields: fields, boundary: boundary, in: tempDir)
    }
    let sem = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var data: Data?; var response: URLResponse?; var error: Error? }
    let box = Box()
    let done: @Sendable (Data?, URLResponse?, Error?) -> Void = { d, resp, e in
      box.data = d; box.response = resp; box.error = e
      sem.signal()
    }
    let task = upload.map { session.uploadTask(with: r, fromFile: $0, completionHandler: done) }
      ?? session.dataTask(with: r, completionHandler: done)
    task.resume()
    if sem.wait(timeout: .now() + request.timeout + 5) == .timedOut {
      task.cancel()
      throw PostizError.network("timed out after \(Int(request.timeout)) s")
    }
    if let e = box.error {
      let ns = e as NSError
      // These fail before any byte reaches Postiz: a definite "not sent".
      let never: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                             NSURLErrorDNSLookupFailed]
      if ns.domain == NSURLErrorDomain, never.contains(ns.code) { throw PostizError.notSent(ns.localizedDescription) }
      throw PostizError.network(ns.localizedDescription)
    }
    guard let http = box.response as? HTTPURLResponse else { throw PostizError.network("no HTTP response") }
    return PostizHTTPResponse(status: http.statusCode, body: box.data ?? Data())
  }
}

/// Builds a multipart body in a temp file, copying the media in 1 MB chunks.
enum Multipart {
  /// Removes upload bodies left by a process that died mid-upload (older than an hour).
  static func sweep(_ dir: URL) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
    for n in names where n.hasPrefix("djq-upload-") && n.hasSuffix(".multipart") {
      let u = dir.appendingPathComponent(n)
      if let d = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date, Date().timeIntervalSince(d) > 3600 {
        try? fm.removeItem(at: u)
      }
    }
  }

  static func write(file: URL, fileName: String, mimeType: String, fields: [String: String], boundary: String,
                    in dir: URL) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appendingPathComponent("djq-upload-\(UUID().uuidString).multipart")
    guard fm.createFile(atPath: out.path, contents: nil) else { throw PostizError.network("can't create \(out.lastPathComponent)") }
    let w = try FileHandle(forWritingTo: out)
    defer { try? w.close() }
    func put(_ s: String) throws { try w.write(contentsOf: Data(s.utf8)) }
    for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
      try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
    }
    let safe = fileName.replacingOccurrences(of: "\"", with: "'")
    try put("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
    let r = try FileHandle(forReadingFrom: file)
    defer { try? r.close() }
    while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty { try w.write(contentsOf: chunk) }
    try put("\r\n--\(boundary)--\r\n")
    return out
  }
}

// MARK: Errors

public enum PostizError: Error, Equatable, Sendable, CustomStringConvertible {
  case unauthorized(String)
  case rateLimited
  case validation(String)
  case notFound
  case payloadTooLarge
  case server(Int, String)
  case network(String)
  /// The request never left the Mac (no connection, host not found): definitely not received by Postiz.
  case notSent(String)
  /// The response didn't have the expected shape.
  case badResponse(String)
  /// No key in the Keychain.
  case noKey
  /// The shared hourly budget (or a 429 pause) doesn't allow another call now.
  case overBudget

  public var description: String {
    switch self {
    case .unauthorized(let m): "Postiz refused the API key\(m.isEmpty ? "" : ": \(m)")"
    case .rateLimited: "Postiz rate limit reached (429)"
    case .validation(let m): "Postiz rejected it: \(m)"
    case .notFound: "Not found in Postiz"
    case .payloadTooLarge: "Too large for Postiz (413)"
    case .server(let s, let m): "Postiz server error \(s)\(m.isEmpty ? "" : ": \(m)")"
    case .network(let m): "Can't reach Postiz: \(m)"
    case .notSent(let m): "Can't reach Postiz (nothing was sent): \(m)"
    case .badResponse(let m): "Unexpected Postiz response: \(m)"
    case .noKey: "No Postiz API key in the Keychain"
    case .overBudget: "Postiz request budget used up for now"
    }
  }

  /// HTTP status → error (nil for 2xx).
  static func from(status: Int, body: Data) -> PostizError? {
    guard !(200..<300).contains(status) else { return nil }
    let m = message(in: body)
    switch status {
    case 401, 403: return .unauthorized(m)
    case 400, 422: return .validation(m.isEmpty ? "invalid request (\(status))" : m)
    case 404: return .notFound
    case 413: return .payloadTooLarge
    case 429: return .rateLimited
    default: return .server(status, m)
    }
  }

  /// `message` (string or array of strings) or `error` from a JSON error body; else a short text prefix.
  static func message(in body: Data) -> String {
    if let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
      if let s = o["message"] as? String { return s }
      if let a = o["message"] as? [Any] { return a.map { "\($0)" }.joined(separator: "; ") }
      if let s = o["error"] as? String { return s }
    }
    let s = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.hasPrefix("<") ? "" : s
  }
}

// MARK: Models

/// A connected channel (`GET /integrations`).
public struct PostizIntegration: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  /// Provider, e.g. `tiktok-business`, `instagram-standalone`, `youtube`, `x`.
  public var identifier: String
  public var picture: String?
  public var disabled: Bool
  public var profile: String?
  /// Postiz's `refreshNeeded`: the channel's sign-in expired and it must be reconnected in Postiz. nil when the list
  /// didn't say (an older Postiz, or a cache written before round 22).
  public var refreshNeeded: Bool?
  public init(id: String, name: String, identifier: String, picture: String? = nil, disabled: Bool = false, profile: String? = nil,
              refreshNeeded: Bool? = nil) {
    self.id = id; self.name = name; self.identifier = identifier; self.picture = picture; self.disabled = disabled
    self.profile = profile
    self.refreshNeeded = refreshNeeded
  }

  /// Disabled, or its sign-in needs refreshing: nothing posts on it until Eric reconnects it in Postiz (round 22: its
  /// posts wait for that, they don't fall back to Manual).
  public var needsSignIn: Bool { disabled || refreshNeeded == true }

  /// The DJ Queue platform this provider posts to (nil for providers DJ Queue doesn't use).
  public var platform: Platform? { PostizPlatforms.platform(forProvider: identifier) }
}

public struct PostizMedia: Codable, Sendable, Hashable {
  public var id: String
  public var path: String
  /// "ready" | "processing" (nil when Postiz didn't say).
  public var status: String?
  public init(id: String, path: String, status: String? = nil) { self.id = id; self.path = path; self.status = status }
}

/// One entry of `GET /posts` (only the fields DJ Queue reads).
public struct PostizRemotePost: Codable, Sendable, Hashable {
  /// The platform has the post, whatever `state` says: a link, or an id. "missing" counts: it's Postiz's word for a post
  /// that went out and whose platform id didn't come back (docs/postiz.md §5).
  public var hasRelease: Bool { !(releaseURL ?? "").isEmpty || !(releaseId ?? "").isEmpty }
  public var id: String
  public var group: String?
  public var publishDate: Date?
  public var state: String
  public var error: String?
  public var releaseURL: String?
  public var releaseId: String?
  public var integrationId: String?
  public var content: String?
  public init(id: String, group: String? = nil, publishDate: Date? = nil, state: String, error: String? = nil,
              releaseURL: String? = nil, releaseId: String? = nil, integrationId: String? = nil, content: String? = nil) {
    self.id = id; self.group = group; self.publishDate = publishDate; self.state = state; self.error = error
    self.releaseURL = releaseURL; self.releaseId = releaseId; self.integrationId = integrationId; self.content = content
  }
}

public struct PostizCreated: Codable, Sendable, Hashable {
  public var postId: String
  public var integration: String?
}

public enum PostizPlatforms {
  /// Default provider identifier (`settings.__type`) per platform (docs/postiz.md §3).
  public static func provider(_ p: Platform) -> String {
    switch p {
    case .instagram: "instagram-standalone"
    case .tiktok: "tiktok-business"
    case .facebook: "facebook"
    case .youtube: "youtube"
    case .threads: "threads"
    case .x: "x"
    }
  }

  public static func platform(forProvider id: String) -> Platform? {
    let s = id.lowercased()
    if s.hasPrefix("instagram") { return .instagram }
    if s.hasPrefix("tiktok") { return .tiktok }
    if s == "facebook" { return .facebook }
    if s.hasPrefix("youtube") { return .youtube }
    if s.hasPrefix("threads") { return .threads }
    if s == "x" || s == "twitter" { return .x }
    return nil
  }
}

// MARK: Client

/// Typed calls over a transport. `key` is fetched per call and goes only into the `Authorization` header.
public final class PostizClient: @unchecked Sendable {
  public let transport: PostizTransport
  public let base: URL
  let key: () throws -> String

  public init(transport: PostizTransport, base: String = PublishingSettings.cloudAPIBase, key: @escaping () throws -> String) {
    self.transport = transport
    self.base = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base) ?? URL(string: PublishingSettings.cloudAPIBase)!
    self.key = key
  }

  public static let jsonTimeout: TimeInterval = 30

  /// Upload timeout: 2 min + 2 s per MB (a 300 MB render gets 12 min).
  public static func uploadTimeout(bytes: Int64) -> TimeInterval { 120 + Double(max(0, bytes)) / 500_000 }

  static let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
  }()

  static let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  /// ISO 8601 UTC with milliseconds, e.g. 2026-11-10T00:00:00.000Z.
  public static func isoString(_ d: Date) -> String { iso.string(from: d) }

  static func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return iso.date(from: s) ?? isoPlain.date(from: s)
  }

  func url(_ path: String, query: [(String, String)] = []) -> URL {
    var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
    return c.url!
  }

  @discardableResult
  func call(_ method: String, _ path: String, query: [(String, String)] = [], body: PostizHTTPRequest.Body = .none,
            timeout: TimeInterval = PostizClient.jsonTimeout) throws -> Data {
    let req = PostizHTTPRequest(method: method, url: url(path, query: query),
                                headers: ["Authorization": try key(), "Accept": "application/json"], body: body, timeout: timeout)
    let resp = try transport.send(req)
    if let e = PostizError.from(status: resp.status, body: resp.body) { throw e }
    return resp.body
  }

  func object(_ d: Data) throws -> Any {
    do { return try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) } catch {
      throw PostizError.badResponse("not JSON")
    }
  }

  // MARK: Endpoints

  public func isConnected() throws -> Bool {
    let o = try object(try call("GET", "is-connected"))
    return (o as? [String: Any])?["connected"] as? Bool ?? false
  }

  public func integrations() throws -> [PostizIntegration] {
    guard let a = try object(try call("GET", "integrations")) as? [[String: Any]] else {
      throw PostizError.badResponse("integrations is not a list")
    }
    return a.compactMap { o in
      guard let id = o["id"] as? String else { return nil }
      return PostizIntegration(id: id, name: o["name"] as? String ?? id,
                               identifier: o["identifier"] as? String ?? o["providerIdentifier"] as? String ?? "",
                               picture: o["picture"] as? String, disabled: o["disabled"] as? Bool ?? false,
                               profile: o["profile"] as? String, refreshNeeded: o["refreshNeeded"] as? Bool)
    }
  }

  /// `GET /integration-settings/{id}`: the raw JSON and the caption `maxLength` when present.
  public func integrationSettings(_ id: String) throws -> (maxLength: Int?, raw: Data) {
    let d = try call("GET", "integration-settings/\(id)")
    let o = try object(d) as? [String: Any]
    let out = o?["output"] as? [String: Any] ?? o
    return (out?["maxLength"] as? Int, d)
  }

  public func upload(file: URL, mimeType: String) throws -> PostizMedia {
    let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    let d = try call("POST", "upload", body: .multipart(file: file, fileName: file.lastPathComponent, mimeType: mimeType,
                                                        fields: ["adjust": "false"]),
                     timeout: Self.uploadTimeout(bytes: size))
    guard let o = try object(d) as? [String: Any], let id = o["id"] as? String, let path = o["path"] as? String else {
      throw PostizError.badResponse("upload returned no id/path")
    }
    return PostizMedia(id: id, path: path, status: o["status"] as? String)
  }

  /// "ready" | "processing" (anything else is returned as written).
  public func mediaStatus(_ id: String) throws -> String {
    let o = try object(try call("GET", "media/\(id)/status"))
    if let s = o as? String { return s }
    return ((o as? [String: Any])?["status"] as? String) ?? "unknown"
  }

  /// `POST /posts` with a body built by `PostizPayload`.
  public func createPost(_ body: Data) throws -> [PostizCreated] {
    let o = try object(try call("POST", "posts", body: .json(body)))
    let list = (o as? [[String: Any]]) ?? ((o as? [String: Any]).map { [$0] } ?? [])
    let out = list.compactMap { e -> PostizCreated? in
      guard let id = e["postId"] as? String ?? e["id"] as? String else { return nil }
      return PostizCreated(postId: id, integration: e["integration"] as? String)
    }
    guard !out.isEmpty else { throw PostizError.badResponse("create returned no postId") }
    return out
  }

  public func posts(from start: Date, to end: Date) throws -> [PostizRemotePost] {
    let d = try call("GET", "posts", query: [("startDate", Self.isoString(start)), ("endDate", Self.isoString(end))])
    let o = try object(d)
    let list = ((o as? [String: Any])?["posts"] as? [[String: Any]]) ?? (o as? [[String: Any]])
    guard let list else { throw PostizError.badResponse("posts is not a list") }
    return list.compactMap { p in
      guard let id = p["id"] as? String else { return nil }
      let integ = (p["integration"] as? [String: Any])?["id"] as? String ?? p["integrationId"] as? String
      return PostizRemotePost(id: id, group: p["group"] as? String, publishDate: Self.parseDate(p["publishDate"] as? String),
                              state: (p["state"] as? String ?? "").uppercased(), error: p["error"] as? String,
                              releaseURL: p["releaseURL"] as? String, releaseId: p["releaseId"] as? String,
                              integrationId: integ, content: p["content"] as? String)
    }
  }

  /// Deletes the post's whole group. 404 = already gone (thrown as `.notFound`; callers treat it as done).
  public func deletePost(_ id: String) throws { try call("DELETE", "posts/\(id)") }

  /// Test mode: release a draft ("schedule") or hold it ("draft").
  public func setStatus(_ id: String, schedule: Bool) throws {
    let body = try JSONSerialization.data(withJSONObject: ["status": schedule ? "schedule" : "draft"])
    try call("PUT", "posts/\(id)/status", body: .json(body))
  }

  /// Candidates for a post whose platform id came back "missing": [(platform id, url)].
  public func missing(_ id: String) throws -> [(id: String, url: String)] {
    let o = try object(try call("GET", "posts/\(id)/missing"))
    return ((o as? [[String: Any]]) ?? []).compactMap { e in
      guard let i = e["id"] as? String ?? (e["id"] as? NSNumber)?.stringValue else { return nil }
      return (i, e["url"] as? String ?? "")
    }
  }

  public func setReleaseId(_ id: String, releaseId: String) throws {
    let body = try JSONSerialization.data(withJSONObject: ["releaseId": releaseId])
    try call("PUT", "posts/\(id)/release-id", body: .json(body))
  }

  /// Raw analytics JSON for a post over the last `days` days (parsed defensively by `PostizAnalytics`).
  public func analytics(_ id: String, days: Int = 7) throws -> Data {
    try call("GET", "analytics/post/\(id)", query: [("date", String(days))])
  }
}
