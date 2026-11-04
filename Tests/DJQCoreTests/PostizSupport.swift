import Foundation
@testable import DJQCore

/// An in-memory Postiz server behind `PostizTransport`. No network: it parses the requests the client builds and
/// answers like the public API (docs/postiz.md §2). Failure injection and invariant checks for the lifecycle tests.
final class FakePostiz: PostizTransport, @unchecked Sendable {
  struct Post {
    var id: String
    var group: String
    var integrationId: String
    var date: Date
    var type: String  // schedule | draft
    var state: String  // QUEUE | DRAFT | PUBLISHED | ERROR
    var deleted = false
    var body: [String: Any]
    var releaseURL: String?
    var releaseId: String?
    var error: String?
    var settings: [String: Any] { ((body["posts"] as? [[String: Any]])?.first?["settings"] as? [String: Any]) ?? [:] }
    var content: String {
      (((body["posts"] as? [[String: Any]])?.first?["value"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    }
    var image: [String: Any] {
      ((((body["posts"] as? [[String: Any]])?.first?["value"] as? [[String: Any]])?.first?["image"] as? [[String: Any]])?.first) ?? [:]
    }
  }

  private let lock = NSRecursiveLock()
  var key = "test-key-123"
  var integrations: [PostizIntegration] = Platform.allCases.map {
    PostizIntegration(id: "ch-\($0.rawValue)", name: "DJ Lovd \($0.displayName)", identifier: PostizPlatforms.provider($0))
  }
  private(set) var posts: [String: Post] = [:]
  private(set) var media: [String: (path: String, bytes: Int)] = [:]
  private(set) var requests: [PostizHTTPRequest] = []
  /// "METHOD path" of every request, in order.
  private(set) var log: [String] = []
  /// Things the real server would make a double post or a lost post of.
  private(set) var violations: [String] = []
  private var nextId = 1

  /// Next response for a route prefix ("DELETE posts", "POST posts", "POST upload", "GET posts", …): a status code.
  var failNext: [String: [Int]] = [:]
  /// Probability (0…1) that a DELETE fails with 500, drawn from `rng`.
  var deleteFailRate = 0.0
  var createFailRate = 0.0
  /// One-shot create outcomes, used in order: "500" (refused, nothing made), "garbage" (made, then an unreadable
  /// 2xx), "timeout" (made, then the connection drops).
  var createOutcomes: [String] = []
  /// Every post ever created (also deleted ones), for the global never-double-post checks.
  var everCreated: [Post] { withLock { posts.values.sorted { $0.id < $1.id } } }
  /// Ids that were ever PUBLISHED (a later delete doesn't un-publish).
  private(set) var everPublished: Set<String> = []
  var rng = SeededRNG(seed: 1)
  /// When set, GET /analytics returns this body.
  var analyticsBody: Data?

  func withLock<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }

  var livePosts: [Post] { withLock { posts.values.filter { !$0.deleted }.sorted { $0.id < $1.id } } }
  var createCount: Int { withLock { log.filter { $0 == "POST posts" }.count } }
  var uploadCount: Int { withLock { log.filter { $0 == "POST upload" }.count } }
  var deleteCount: Int { withLock { log.filter { $0.hasPrefix("DELETE posts/") }.count } }
  func calls(_ prefix: String) -> [String] { withLock { log.filter { $0.hasPrefix(prefix) } } }

  func post(_ id: String) -> Post? { withLock { posts[id] } }

  /// Marks every QUEUE (not draft) post whose date passed as PUBLISHED with a release URL.
  func publishDue(now: Date) {
    withLock {
      for (id, p) in posts where !p.deleted && p.state == "QUEUE" && p.date <= now { publish(id) }
    }
  }

  func publish(_ id: String, url: String? = nil, releaseId: String? = nil) {
    withLock {
      guard var p = posts[id] else { return }
      let platform = integrations.first { $0.id == p.integrationId }?.platform ?? .x
      p.state = "PUBLISHED"
      p.releaseURL = url ?? Fixture.postURLs[platform]!.replacingOccurrences(of: "abc", with: id)
      p.releaseId = releaseId ?? "rel-\(id)"
      posts[id] = p
      everPublished.insert(id)
    }
  }

  func fail(_ id: String, error: String?) {
    withLock {
      posts[id]?.state = "ERROR"
      posts[id]?.error = error
    }
  }

  /// Deleted in the Postiz calendar (DJ Queue didn't ask).
  func vanish(_ id: String) { withLock { posts[id]?.deleted = true } }

  func send(_ r: PostizHTTPRequest) throws -> PostizHTTPResponse {
    try withLock {
      requests.append(r)
      let path = String(r.url.path.split(separator: "/").drop { $0 != "v1" }.dropFirst().joined(separator: "/"))
      let route = "\(r.method) \(path)"
      log.append(route)
      guard r.headers["Authorization"] == key else { return json(401, ["message": "Invalid API key"]) }
      for (prefix, codes) in failNext where route.hasPrefix(prefix) && !codes.isEmpty {
        failNext[prefix]!.removeFirst()
        return json(codes[0], ["message": "injected \(codes[0])"])
      }
      let parts = path.split(separator: "/").map(String.init)
      switch (r.method, parts.first ?? "") {
      case ("GET", "is-connected"): return json(200, ["connected": true])
      case ("GET", "integrations"):
        return json(200, integrations.map {
          ["id": $0.id, "name": $0.name, "identifier": $0.identifier, "disabled": $0.disabled, "picture": ""] as [String: Any]
        })
      case ("GET", "integration-settings"): return json(200, ["output": ["maxLength": 2200, "settings": [:], "rules": ""]])
      case ("POST", "upload"):
        guard case .multipart(let file, _, _, let fields) = r.body, fields["adjust"] == "false",
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else {
          return json(400, ["message": "Unsupported file type."])
        }
        let id = "m\(nextId)"
        nextId += 1
        media[id] = ("https://uploads.example/\(id).mp4", size)
        return json(200, ["id": id, "name": file.lastPathComponent, "path": media[id]!.path, "status": "ready"])
      case ("GET", "media"): return json(200, ["status": "ready"])
      case ("POST", "posts"):
        let outcome = createOutcomes.isEmpty ? "" : createOutcomes.removeFirst()
        if outcome == "500" { return json(500, ["message": "injected 500"]) }
        if createFailRate > 0, Double.random(in: 0..<1, using: &rng) < createFailRate { return json(500, ["message": "flaky"]) }
        guard case .json(let d) = r.body, let body = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let items = body["posts"] as? [[String: Any]], let type = body["type"] as? String,
              let date = PostizClient.parseDate(body["date"] as? String) else { return json(400, ["message": "bad body"]) }
        var out: [[String: Any]] = []
        for item in items {
          let integ = (item["integration"] as? [String: Any])?["id"] as? String ?? ""
          guard integrations.contains(where: { $0.id == integ }) else { return json(400, ["message": "integration not found"]) }
          let media = ((((item["value"] as? [[String: Any]])?.first?["image"]) as? [[String: Any]])?.first?["id"] as? String) ?? ""
          guard self.media[media] != nil else { return json(400, ["message": "media not found"]) }
          let id = "p\(nextId)"
          nextId += 1
          posts[id] = Post(id: id, group: "g-\(id)", integrationId: integ, date: date, type: type,
                           state: type == "draft" ? "DRAFT" : "QUEUE",
                           body: ["type": type, "posts": [item]])
          out.append(["postId": id, "integration": integ])
        }
        if outcome == "garbage" { return PostizHTTPResponse(status: 201, body: Data("<html>ok</html>".utf8)) }
        if outcome == "timeout" { throw PostizError.network("timed out after 30 s") }
        return json(200, out)
      case ("GET", "posts") where parts.count == 1:
        let q = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let s = PostizClient.parseDate(q.first { $0.name == "startDate" }?.value),
              let e = PostizClient.parseDate(q.first { $0.name == "endDate" }?.value) else { return json(400, ["message": "dates"]) }
        let list = posts.values.filter { !$0.deleted && $0.date >= s && $0.date <= e }.sorted { $0.id < $1.id }.map { p in
          var o: [String: Any] = ["id": p.id, "group": p.group, "publishDate": PostizClient.isoString(p.date), "state": p.state,
                                  "integration": ["id": p.integrationId, "providerIdentifier": "x"], "content": p.content]
          o["releaseURL"] = p.releaseURL ?? NSNull()
          o["releaseId"] = p.releaseId ?? NSNull()
          o["error"] = p.error ?? NSNull()
          return o
        }
        return json(200, ["posts": list])
      case ("DELETE", "posts"):
        let id = parts.count > 1 ? parts[1] : ""
        guard let p = posts[id], !p.deleted else { return json(404, ["message": "not found"]) }
        if p.state == "PUBLISHED" { violations.append("DELETE of published \(id)") }
        if deleteFailRate > 0, Double.random(in: 0..<1, using: &rng) < deleteFailRate { return json(500, ["message": "flaky"]) }
        for (k, q) in posts where q.group == p.group { posts[k]!.deleted = true }
        return json(200, ["id": id])
      case ("PUT", "posts") where parts.count == 3 && parts[2] == "status":
        guard case .json(let d) = r.body, let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let st = o["status"] as? String, posts[parts[1]] != nil else { return json(404, ["message": "not found"]) }
        posts[parts[1]]!.state = st == "schedule" ? "QUEUE" : "DRAFT"
        return json(200, ["id": parts[1], "state": posts[parts[1]]!.state])
      case ("GET", "posts") where parts.count == 3 && parts[2] == "missing":
        return json(200, [["id": "777", "url": "https://www.tiktok.com/@dj.lovd/video/777"]])
      case ("PUT", "posts") where parts.count == 3 && parts[2] == "release-id":
        guard case .json(let d) = r.body, let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
          return json(400, ["message": "bad"])
        }
        posts[parts[1]]?.releaseId = o["releaseId"] as? String
        return json(200, ["id": parts[1]])
      case ("GET", "analytics"):
        if let b = analyticsBody { return PostizHTTPResponse(status: 200, body: b) }
        return json(200, [["label": "Views", "data": [["total": 10, "date": "2026-11-02"], ["total": 25, "date": "2026-11-03"]]],
                          ["label": "Likes", "data": [["total": "3", "date": "2026-11-03"]]]])
      default:
        return json(404, ["message": "no route \(route)"])
      }
    }
  }

  private func json(_ status: Int, _ o: Any) -> PostizHTTPResponse {
    PostizHTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
  }
}

/// Deterministic RNG for fuzz tests.
struct SeededRNG: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
}
