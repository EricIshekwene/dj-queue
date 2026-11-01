import DJQCore
import Foundation

/// DJQCore's record structs (Week, PlanSlot, PlatformPost, Render) have no public memberwise init, so the app
/// builds new ones through their Codable conformance. Labels mirror the memberwise initialisers.
enum Records {
  private static func make<T: Decodable>(_ fields: [String: Any?]) -> T {
    let clean = fields.compactMapValues { v -> Any? in
      switch v {
      case .none: return nil
      case .some(let d as Date): return d.timeIntervalSince1970
      case .some(let x): return x
      }
    }
    do {
      return try JSONCoding.decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: clean))
    } catch {
      fatalError("Records.make(\(T.self)): \(error)")
    }
  }

  static func week(weekStart: String, state: WeekState, approvedAt: Date?) -> Week {
    make(["weekStart": weekStart, "state": state.rawValue, "approvedAt": approvedAt])
  }

  static func planSlot(id: String, date: String, position: Int, videoId: String, pinned: Bool, weekStart: String) -> PlanSlot {
    make(["id": id, "date": date, "position": position, "videoId": videoId, "pinned": pinned, "weekStart": weekStart])
  }

  static func platformPost(id: String, videoId: String, platform: Platform, versionNo: Int, attemptNo: Int, kind: PostKind,
                           planSlotId: String?, scheduledAt: Date, renderId: String?, state: PostState, publisher: String,
                           externalId: String?, url: String?, postedAt: Date?, errorType: ErrorType?, errorMessage: String?,
                           rawResponse: String?, resolution: String?, metrics: PostMetrics?, createdAt: Date, updatedAt: Date) -> PlatformPost {
    var p: PlatformPost = make([
      "id": id, "videoId": videoId, "platform": platform.rawValue, "versionNo": versionNo, "attemptNo": attemptNo,
      "kind": kind.rawValue, "planSlotId": planSlotId, "scheduledAt": scheduledAt, "renderId": renderId, "state": state.rawValue,
      "publisher": publisher, "externalId": externalId, "url": url, "postedAt": postedAt, "errorType": errorType?.rawValue,
      "errorMessage": errorMessage, "rawResponse": rawResponse, "resolution": resolution, "createdAt": createdAt, "updatedAt": updatedAt,
    ])
    p.metrics = metrics
    return p
  }

  static func render(id: String, videoId: String, versionNo: Int, editHash: String, scope: String, outputPath: String?,
                     coverPath: String?, loudness: LoudnessInfo?, duration: Double?, size: Int64?, status: RenderStatus,
                     error: String?, createdAt: Date, deletedAt: Date?) -> Render {
    var r: Render = make([
      "id": id, "videoId": videoId, "versionNo": versionNo, "editHash": editHash, "scope": scope, "outputPath": outputPath,
      "coverPath": coverPath, "duration": duration, "size": size, "status": status.rawValue, "error": error,
      "createdAt": createdAt, "deletedAt": deletedAt,
    ])
    r.loudness = loudness
    return r
  }
}
