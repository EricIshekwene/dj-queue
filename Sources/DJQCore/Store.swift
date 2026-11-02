import Foundation

/// The app's database (spec §3): single source of truth for everything that changes.
/// The GUI, the engine and the `djq` CLI all open the same file (WAL).
public final class Store: @unchecked Sendable {
  public let db: SQLite
  public let paths: Paths
  public let clock: Clock

  public static let schemaVersion = 3

  public init(paths: Paths, clock: Clock = SystemClock(), path: String? = nil) throws {
    self.paths = paths
    self.clock = clock
    try paths.ensure()
    db = try SQLite(path: path ?? paths.database.path)
    try migrate()
  }

  /// In-memory store for tests.
  public init(memoryWith paths: Paths, clock: Clock) throws {
    self.paths = paths
    self.clock = clock
    db = try SQLite(path: ":memory:")
    try migrate()
  }

  var now: Date { clock.now }

  // MARK: Schema

  private func migrate() throws {
    let v = try db.one("PRAGMA user_version")?.int("user_version") ?? 0
    if v < 1 {
      try db.exec("""
      CREATE TABLE IF NOT EXISTS sessions(
        id TEXT PRIMARY KEY, folder TEXT NOT NULL, name TEXT NOT NULL, date TEXT,
        discovered_at REAL NOT NULL, missing INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS videos(
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id),
        name TEXT NOT NULL, tags TEXT NOT NULL, type TEXT NOT NULL, content_type TEXT NOT NULL,
        kind TEXT NOT NULL, file TEXT NOT NULL, fingerprint TEXT, file_size INTEGER,
        duration REAL NOT NULL, marked_start REAL, marked_end REAL, start REAL, "end" REAL, grace REAL,
        audio TEXT, part INTEGER, score INTEGER, state TEXT NOT NULL, excluded INTEGER NOT NULL DEFAULT 0,
        missing INTEGER NOT NULL DEFAULT 0, in_manifest INTEGER NOT NULL DEFAULT 1, notes TEXT NOT NULL DEFAULT '',
        already_posted_on TEXT NOT NULL DEFAULT '[]', longform_url TEXT,
        created_at REAL NOT NULL, updated_at REAL NOT NULL);
      CREATE INDEX IF NOT EXISTS videos_session ON videos(session_id);
      CREATE TABLE IF NOT EXISTS edits(video_id TEXT PRIMARY KEY REFERENCES videos(id), json TEXT NOT NULL, updated_at REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS versions(video_id TEXT NOT NULL REFERENCES videos(id), number INTEGER NOT NULL,
        json TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY(video_id, number));
      CREATE TABLE IF NOT EXISTS hashtag_sets(id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL,
        tags TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS caption_templates(id TEXT PRIMARY KEY, name TEXT NOT NULL, template TEXT NOT NULL,
        sort INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS weeks(week_start TEXT PRIMARY KEY, state TEXT NOT NULL, approved_at REAL);
      CREATE TABLE IF NOT EXISTS plan_slots(id TEXT PRIMARY KEY, date TEXT NOT NULL, position INTEGER NOT NULL,
        video_id TEXT NOT NULL REFERENCES videos(id), pinned INTEGER NOT NULL DEFAULT 0, week_start TEXT NOT NULL,
        UNIQUE(date, position));
      CREATE TABLE IF NOT EXISTS platform_posts(
        id TEXT PRIMARY KEY, video_id TEXT NOT NULL REFERENCES videos(id), platform TEXT NOT NULL,
        version_no INTEGER NOT NULL, attempt_no INTEGER NOT NULL, kind TEXT NOT NULL, plan_slot_id TEXT,
        scheduled_at REAL NOT NULL, render_id TEXT, state TEXT NOT NULL, publisher TEXT NOT NULL,
        external_id TEXT, url TEXT, posted_at REAL, error_type TEXT, error_message TEXT, raw_response TEXT,
        resolution TEXT, metrics TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
      CREATE INDEX IF NOT EXISTS posts_video ON platform_posts(video_id);
      CREATE INDEX IF NOT EXISTS posts_sched ON platform_posts(scheduled_at);
      CREATE TABLE IF NOT EXISTS post_history(id INTEGER PRIMARY KEY AUTOINCREMENT, post_id TEXT NOT NULL,
        at REAL NOT NULL, from_state TEXT, to_state TEXT NOT NULL, note TEXT);
      CREATE TABLE IF NOT EXISTS renders(id TEXT PRIMARY KEY, video_id TEXT NOT NULL, version_no INTEGER NOT NULL,
        edit_hash TEXT NOT NULL, scope TEXT NOT NULL, output_path TEXT, cover_path TEXT, loudness TEXT,
        duration REAL, size INTEGER, status TEXT NOT NULL, error TEXT, created_at REAL NOT NULL, deleted_at REAL);
      CREATE INDEX IF NOT EXISTS renders_key ON renders(video_id, version_no, edit_hash, scope);
      CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL,
        message TEXT NOT NULL, video_id TEXT, post_id TEXT);
      CREATE INDEX IF NOT EXISTS events_at ON events(at);
      CREATE TABLE IF NOT EXISTS heartbeats(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS heartbeats_at ON heartbeats(at);
      CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, json TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS sent_notifications(key TEXT PRIMARY KEY, at REAL NOT NULL);
      PRAGMA user_version = 1;
      """)
      try seedDefaults()
    }
    if v < 2 { try migrateToV2(from: v) }
    if v < 3 { try migrateToV3(from: v) }
    // Idempotent additions to v2 (dev databases created before they existed).
    let bcols = Set(try db.query("PRAGMA table_info(batches)").compactMap { $0.string("name") })
    if !bcols.contains("restored") { try db.exec("ALTER TABLE batches ADD COLUMN restored TEXT NOT NULL DEFAULT '[]'") }
  }

  /// Round 2: titles + suggestions, batch journal, cached source size, override-only edits.
  /// Lossless: every edit resolves to exactly what it did before (values equal to the round-1 hard defaults —
  /// aspect 9:16, cover includes text — become "follow the default", whose seeded values are the same).
  /// A file database with data is copied to `<app support>/backups/` first.
  private func migrateToV2(from v: Int) throws {
    if v >= 1, db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM videos")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-schema2-\(f.string(from: Date())).sqlite").path)
    }
    try db.transaction {
      let cols = Set(try db.query("PRAGMA table_info(videos)").compactMap { $0.string("name") })
      for (c, t) in [("title", "TEXT"), ("title_tracks", "TEXT"), ("title_source", "TEXT"),
                     ("source_width", "INTEGER"), ("source_height", "INTEGER")] where !cols.contains(c) {
        try db.exec("ALTER TABLE videos ADD COLUMN \(c) \(t)")
      }
      try db.exec("""
        CREATE TABLE IF NOT EXISTS title_suggestions(id INTEGER PRIMARY KEY AUTOINCREMENT,
          video_id TEXT NOT NULL REFERENCES videos(id), text TEXT NOT NULL, tracks TEXT NOT NULL DEFAULT '[]',
          confidence REAL, source TEXT NOT NULL DEFAULT '', origin TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, UNIQUE(video_id, origin, text, source));
        CREATE INDEX IF NOT EXISTS suggestions_video ON title_suggestions(video_id);
        CREATE TABLE IF NOT EXISTS batches(id TEXT PRIMARY KEY, action TEXT NOT NULL, params TEXT, video_ids TEXT NOT NULL,
          before TEXT NOT NULL, after TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
          undone_at REAL, restored TEXT NOT NULL DEFAULT '[]');
        """)
      for r in try db.query("SELECT video_id, json FROM edits") {
        guard let id = r.string("video_id"), let s = r.string("json"),
              var obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { continue }
        if obj["aspect"] as? String == Aspect.r9x16.rawValue { obj.removeValue(forKey: "aspect") }
        if let b = obj["coverIncludesText"] as? Bool, b { obj.removeValue(forKey: "coverIncludesText") }
        // Unreadable rows are left exactly as they are (Doctor reports them).
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let e = try? JSONCoding.decoder.decode(Edit.self, from: d) else { continue }
        try db.run("UPDATE edits SET json=? WHERE video_id=?", [JSONCoding.string(e), id])
      }
      try db.exec("PRAGMA user_version = 2")
    }
  }

  /// "Remove from queue" (sent back to Edit): one app-owned flag per clip, additive and lossless (every existing
  /// clip starts not held, so no state changes). A file database with data is copied to `<app support>/backups/` first.
  private func migrateToV3(from v: Int) throws {
    if v >= 2, db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM videos")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-schema3-\(f.string(from: Date())).sqlite").path)
    }
    try db.transaction {
      let cols = Set(try db.query("PRAGMA table_info(videos)").compactMap { $0.string("name") })
      if !cols.contains("held_in_edit") {
        try db.exec("ALTER TABLE videos ADD COLUMN held_in_edit INTEGER NOT NULL DEFAULT 0")
      }
      try db.exec("PRAGMA user_version = 3")
    }
  }

  private func seedDefaults() throws {
    if try hashtagSets().isEmpty {
      for s in Defaults.hashtagSets { try save(s) }
    }
    if try captionTemplates().isEmpty {
      for t in Defaults.captionTemplates { try save(t) }
    }
  }

  // MARK: Key-value (settings and small state)

  public func kv<T: Decodable>(_ key: String, as: T.Type = T.self) throws -> T? {
    try db.one("SELECT json FROM kv WHERE key=?", [key])?.json("json")
  }

  public func setKV<T: Encodable>(_ key: String, _ value: T) throws {
    try db.run("INSERT INTO kv(key,json) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET json=excluded.json",
               [key, JSONCoding.string(value)])
  }

  /// Settings with any keys missing from older stored JSON filled from defaults. A corrupt row is
  /// logged and defaults are used in memory; the row is only replaced when Settings are saved.
  public func settings() throws -> Settings {
    guard let s = try db.one("SELECT json FROM kv WHERE key='settings'")?.string("json") else { return Settings() }
    do {
      var out = try JSONCoding.decodeLenient(Data(s.utf8), defaults: Settings())
      // Round-1 rows kept the text/caption defaults at the top level: carry them into `defaults` once.
      if let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any], obj["defaults"] == nil {
        if let x = (obj["defaultStyle"] as? String).flatMap(TextStyle.init) { out.defaults.textStyle = x }
        if let x = obj["defaultTextSize"] as? Double { out.defaults.textSize = x }
        if let x = obj["defaultPosY"] as? Double { out.defaults.textPosY = x }
        if let x = obj["defaultCaptionTemplateId"] as? String { out.defaults.captionTemplateId = x }
        if let x = obj["defaultHashtagSetIds"] as? [String] { out.defaults.hashtagSetIds = x }
      }
      return out
    } catch {
      Log.shared.error("settings unreadable, using defaults in memory: \(error)")
      return Settings()
    }
  }
  public func save(_ s: Settings) throws { try setKV("settings", s) }

  // MARK: Sessions

  public func sessions() throws -> [Session] {
    try db.query("SELECT * FROM sessions ORDER BY date DESC, name DESC").map(Self.session)
  }

  public func session(id: String) throws -> Session? {
    try db.one("SELECT * FROM sessions WHERE id=?", [id]).map(Self.session)
  }

  public func save(_ s: Session) throws {
    try db.run("""
      INSERT INTO sessions(id,folder,name,date,discovered_at,missing) VALUES(?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET folder=excluded.folder, name=excluded.name, date=excluded.date, missing=excluded.missing
      """, [s.id, s.folder, s.name, s.date, s.discoveredAt, s.missing])
  }

  static func session(_ r: Row) -> Session {
    Session(id: r.string("id")!, folder: r.string("folder")!, name: r.string("name")!, date: r.string("date"),
            discoveredAt: r.date("discovered_at")!, missing: r.bool("missing"))
  }

  // MARK: Videos

  public func videos(where clause: String = "1", _ binds: [SQLBindable?] = []) throws -> [Video] {
    try db.query("SELECT * FROM videos WHERE \(clause)", binds).map(Self.video)
  }

  public func video(id: String) throws -> Video? {
    try db.one("SELECT * FROM videos WHERE id=?", [id]).map(Self.video)
  }

  public func save(_ v: Video) throws {
    try db.run("""
      INSERT INTO videos(id,session_id,name,tags,type,content_type,kind,file,fingerprint,file_size,duration,
        marked_start,marked_end,start,"end",grace,audio,part,score,state,excluded,missing,in_manifest,notes,
        already_posted_on,longform_url,created_at,updated_at,title,title_tracks,title_source,source_width,source_height,
        held_in_edit)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id, name=excluded.name, tags=excluded.tags,
        type=excluded.type, content_type=excluded.content_type, kind=excluded.kind, file=excluded.file,
        fingerprint=excluded.fingerprint, file_size=excluded.file_size, duration=excluded.duration,
        marked_start=excluded.marked_start, marked_end=excluded.marked_end, start=excluded.start, "end"=excluded."end",
        grace=excluded.grace, audio=excluded.audio, part=excluded.part, score=excluded.score, state=excluded.state,
        excluded=excluded.excluded, missing=excluded.missing, in_manifest=excluded.in_manifest, notes=excluded.notes,
        already_posted_on=excluded.already_posted_on, longform_url=excluded.longform_url, updated_at=excluded.updated_at,
        title=excluded.title, title_tracks=excluded.title_tracks, title_source=excluded.title_source,
        source_width=excluded.source_width, source_height=excluded.source_height, held_in_edit=excluded.held_in_edit
      """, [v.id, v.sessionId, v.name, JSONCoding.string(v.tags), v.type.rawValue, v.contentType, v.kind.rawValue,
            v.file, v.fingerprint, v.fileSize, v.duration, v.markedStart, v.markedEnd, v.start, v.end, v.grace,
            v.audio, v.part, v.score, v.state.rawValue, v.excluded, v.missing, v.inManifest, v.notes,
            JSONCoding.string(v.alreadyPostedOn), v.longformURL, v.createdAt, v.updatedAt, v.title,
            v.titleTracks.map { JSONCoding.string($0) }, v.titleSource, v.sourceWidth, v.sourceHeight, v.heldInEdit])
  }

  /// Updates only the fields that come from videos.json / the file (spec §4: never overwrite app-owned fields).
  public func saveIdentity(_ v: Video) throws {
    try db.run("""
      UPDATE videos SET session_id=?, name=?, tags=?, type=?, content_type=?, file=?, fingerprint=?, file_size=?,
        duration=?, marked_start=?, marked_end=?, start=?, "end"=?, grace=?, audio=?, part=?, missing=?, in_manifest=?,
        updated_at=? WHERE id=?
      """, [v.sessionId, v.name, JSONCoding.string(v.tags), v.type.rawValue, v.contentType, v.file, v.fingerprint,
            v.fileSize, v.duration, v.markedStart, v.markedEnd, v.start, v.end, v.grace, v.audio, v.part, v.missing,
            v.inManifest, now, v.id])
  }

  public func setLongformURL(_ id: String, _ url: String?) throws {
    try db.run("UPDATE videos SET longform_url=?, updated_at=? WHERE id=?", [url, now, id])
    try refreshState(videoId: id)
  }

  public func setAlreadyPostedOn(_ id: String, _ platforms: [Platform]) throws {
    try db.run("UPDATE videos SET already_posted_on=?, updated_at=? WHERE id=?", [JSONCoding.string(platforms), now, id])
  }

  public func setScore(_ id: String, _ score: Int?) throws {
    try db.run("UPDATE videos SET score=?, updated_at=? WHERE id=?", [score.map { min(100, max(0, $0)) }, now, id])
    try logEvent("score", "Score \(score.map(String.init) ?? "cleared")", videoId: id)
  }

  public func setExcluded(_ id: String, _ excluded: Bool) throws {
    try db.run("UPDATE videos SET excluded=?, updated_at=? WHERE id=?", [excluded, now, id])
    try refreshState(videoId: id)
  }

  public func setKind(_ id: String, _ kind: Kind) throws {
    try db.run("UPDATE videos SET kind=?, updated_at=? WHERE id=?", [kind.rawValue, now, id])
    try refreshState(videoId: id)  // "No text for Talking" can change readiness
  }

  /// "Remove from queue" / "Send to queue": while held, the clip stays in Edit (state `needs_edit`, issue
  /// "Sent back from Queue") even when everything else is valid, so the planner never picks it. Plan slots and
  /// posts are not touched here — `BulkActions.removeFromQueue` does that with the planner's rules.
  public func setHeldInEdit(_ id: String, _ held: Bool) throws {
    try db.run("UPDATE videos SET held_in_edit=?, updated_at=? WHERE id=?", [held, now, id])
    try logEvent("queue", held ? "Sent back to Edit from Queue" : "Sent to Queue", videoId: id)
    try refreshState(videoId: id)
  }

  public func setNotes(_ id: String, _ notes: String) throws {
    try db.run("UPDATE videos SET notes=?, updated_at=? WHERE id=?", [notes, now, id])
  }

  static func video(_ r: Row) -> Video {
    Video(id: r.string("id")!, sessionId: r.string("session_id")!, name: r.string("name")!,
          tags: r.json("tags") ?? [], type: VideoType(rawValue: r.string("type")!) ?? .short,
          contentType: r.string("content_type")!, kind: Kind(rawValue: r.string("kind")!) ?? .djVid,
          file: r.string("file")!, fingerprint: r.string("fingerprint"), fileSize: r.int64("file_size"),
          duration: r.double("duration") ?? 0, markedStart: r.double("marked_start"), markedEnd: r.double("marked_end"),
          start: r.double("start"), end: r.double("end"), grace: r.double("grace"), audio: r.string("audio"),
          part: r.int("part"), score: r.int("score"), state: VideoState(rawValue: r.string("state")!) ?? .needsEdit,
          excluded: r.bool("excluded"), missing: r.bool("missing"), inManifest: r.bool("in_manifest"),
          notes: r.string("notes") ?? "", alreadyPostedOn: r.json("already_posted_on") ?? [],
          longformURL: r.string("longform_url"), createdAt: r.date("created_at")!, updatedAt: r.date("updated_at")!,
          title: r.string("title"), titleTracks: r.json("title_tracks"), titleSource: r.string("title_source"),
          sourceWidth: r.int("source_width"), sourceHeight: r.int("source_height"), heldInEdit: r.bool("held_in_edit"))
  }

  public func fileURL(for v: Video) throws -> URL? {
    if v.file.hasPrefix("/") { return URL(fileURLWithPath: v.file) }  // relinked into another session's folder
    guard let s = try session(id: v.sessionId) else { return nil }
    return URL(fileURLWithPath: s.folder).appendingPathComponent(v.file)
  }

  // MARK: Edits and versions

  /// The video's edit (default `Edit()` when none saved). Keys missing from older JSON keep their defaults;
  /// unreadable JSON throws rather than silently dropping the crop.
  public func edit(videoId: String) throws -> Edit {
    guard let s = try db.one("SELECT json FROM edits WHERE video_id=?", [videoId])?.string("json") else { return Edit() }
    return try JSONCoding.decodeLenient(Data(s.utf8), defaults: Edit())
  }

  public func hasEdit(videoId: String) throws -> Bool {
    try db.one("SELECT 1 AS x FROM edits WHERE video_id=?", [videoId]) != nil
  }

  public func save(_ e: Edit, videoId: String) throws {
    if let c = e.crop, let v = try video(id: videoId), let w = v.sourceWidth, let h = v.sourceHeight, w > 0, h > 0,
       try edit(videoId: videoId).crop != c {
      struct P: Codable { var x: Double; var y: Double }
      try setKV("defaults.lastCropCentre", P(x: (c.x + c.w / 2) / Double(w), y: (c.y + c.h / 2) / Double(h)))
    }
    try db.run("INSERT INTO edits(video_id,json,updated_at) VALUES(?,?,?) ON CONFLICT(video_id) DO UPDATE SET json=excluded.json, updated_at=excluded.updated_at",
               [videoId, JSONCoding.string(e), now])
    try refreshState(videoId: videoId)
  }

  /// All versions in order. An unreadable row throws (so the editor goes read-only) instead of being skipped
  /// and later overwritten.
  public func versions(videoId: String) throws -> [Version] {
    try db.query("SELECT number, json FROM versions WHERE video_id=? ORDER BY number", [videoId]).map { r in
      guard let s = r.string("json"), let v = try? JSONCoding.decoder.decode(Version.self, from: Data(s.utf8)) else {
        throw StoreError.corruptRow("versions", "\(videoId) v\(r.int("number") ?? 0)")
      }
      return v
    }
  }

  public func save(_ v: Version, videoId: String) throws {
    try db.run("INSERT INTO versions(video_id,number,json,updated_at) VALUES(?,?,?,?) ON CONFLICT(video_id,number) DO UPDATE SET json=excluded.json, updated_at=excluded.updated_at",
               [videoId, v.number, JSONCoding.string(v), now])
    try refreshState(videoId: videoId)
  }

  public func deleteVersion(videoId: String, number: Int) throws {
    try db.run("DELETE FROM versions WHERE video_id=? AND number=?", [videoId, number])
    try refreshState(videoId: videoId)
  }

  /// Carry-forward resolution of version `number` (spec §3): empty fields inherit from earlier versions.
  public func resolvedVersion(videoId: String, number: Int, settings: Settings? = nil) throws -> ResolvedVersion? {
    let all = try versions(videoId: videoId).filter { $0.number <= number }
    guard all.contains(where: { $0.number == number }) || number == 1 else { return nil }
    return VersionResolver.resolve(all.isEmpty ? [Version(number: 1)] : all, number: number,
                                   settings: try settings ?? self.settings(), video: try video(id: videoId))
  }

  // MARK: Hashtag sets and caption templates

  public func hashtagSets() throws -> [HashtagSet] {
    try db.query("SELECT * FROM hashtag_sets ORDER BY category, sort, name").map {
      HashtagSet(id: $0.string("id")!, name: $0.string("name")!, category: $0.string("category")!,
                 tags: $0.json("tags") ?? [], sort: $0.int("sort") ?? 0)
    }
  }

  public func save(_ s: HashtagSet) throws {
    try db.run("INSERT INTO hashtag_sets(id,name,category,tags,sort) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, category=excluded.category, tags=excluded.tags, sort=excluded.sort",
               [s.id, s.name, s.category, JSONCoding.string(s.tags), s.sort])
  }

  public func deleteHashtagSet(_ id: String) throws { try db.run("DELETE FROM hashtag_sets WHERE id=?", [id]) }

  public func captionTemplates() throws -> [CaptionTemplate] {
    try db.query("SELECT * FROM caption_templates ORDER BY sort, name").map {
      CaptionTemplate(id: $0.string("id")!, name: $0.string("name")!, template: $0.string("template")!, sort: $0.int("sort") ?? 0)
    }
  }

  public func save(_ t: CaptionTemplate) throws {
    try db.run("INSERT INTO caption_templates(id,name,template,sort) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, template=excluded.template, sort=excluded.sort",
               [t.id, t.name, t.template, t.sort])
  }

  public func deleteCaptionTemplate(_ id: String) throws { try db.run("DELETE FROM caption_templates WHERE id=?", [id]) }

  // MARK: Weeks and plan slots

  public func week(_ start: String) throws -> Week? {
    try db.one("SELECT * FROM weeks WHERE week_start=?", [start]).map {
      Week(weekStart: $0.string("week_start")!, state: WeekState(rawValue: $0.string("state")!) ?? .draft,
           approvedAt: $0.date("approved_at"))
    }
  }

  public func save(_ w: Week) throws {
    try db.run("INSERT INTO weeks(week_start,state,approved_at) VALUES(?,?,?) ON CONFLICT(week_start) DO UPDATE SET state=excluded.state, approved_at=excluded.approved_at",
               [w.weekStart, w.state.rawValue, w.approvedAt])
  }

  public func planSlots(where clause: String = "1", _ binds: [SQLBindable?] = []) throws -> [PlanSlot] {
    try db.query("SELECT * FROM plan_slots WHERE \(clause) ORDER BY date, position", binds).map {
      PlanSlot(id: $0.string("id")!, date: $0.string("date")!, position: $0.int("position")!,
               videoId: $0.string("video_id")!, pinned: $0.bool("pinned"), weekStart: $0.string("week_start")!)
    }
  }

  public func save(_ s: PlanSlot) throws {
    try db.run("INSERT INTO plan_slots(id,date,position,video_id,pinned,week_start) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET date=excluded.date, position=excluded.position, video_id=excluded.video_id, pinned=excluded.pinned, week_start=excluded.week_start",
               [s.id, s.date, s.position, s.videoId, s.pinned, s.weekStart])
  }

  public func deletePlanSlot(_ id: String) throws { try db.run("DELETE FROM plan_slots WHERE id=?", [id]) }

  // MARK: Platform posts

  public func posts(where clause: String = "1", _ binds: [SQLBindable?] = [], order: String = "scheduled_at") throws -> [PlatformPost] {
    try db.query("SELECT * FROM platform_posts WHERE \(clause) ORDER BY \(order)", binds).map(Self.post)
  }

  public func post(id: String) throws -> PlatformPost? {
    try db.one("SELECT * FROM platform_posts WHERE id=?", [id]).map(Self.post)
  }

  /// Insert or update a post; state changes are appended to post_history.
  public func save(_ p: PlatformPost, note: String? = nil) throws {
    let old = try post(id: p.id)
    var p = p
    p.updatedAt = now
    try db.run("""
      INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,plan_slot_id,scheduled_at,render_id,
        state,publisher,external_id,url,posted_at,error_type,error_message,raw_response,resolution,metrics,created_at,updated_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET version_no=excluded.version_no, attempt_no=excluded.attempt_no, kind=excluded.kind,
        plan_slot_id=excluded.plan_slot_id, scheduled_at=excluded.scheduled_at, render_id=excluded.render_id,
        state=excluded.state, publisher=excluded.publisher, external_id=excluded.external_id, url=excluded.url,
        posted_at=excluded.posted_at, error_type=excluded.error_type, error_message=excluded.error_message,
        raw_response=excluded.raw_response, resolution=excluded.resolution, metrics=excluded.metrics,
        updated_at=excluded.updated_at
      """, [p.id, p.videoId, p.platform.rawValue, p.versionNo, p.attemptNo, p.kind.rawValue, p.planSlotId,
            p.scheduledAt, p.renderId, p.state.rawValue, p.publisher, p.externalId, p.url, p.postedAt,
            p.errorType?.rawValue, p.errorMessage, p.rawResponse, p.resolution,
            p.metrics.map { JSONCoding.string($0) }, p.createdAt, p.updatedAt])
    if old?.state != p.state || note != nil {
      try db.run("INSERT INTO post_history(post_id,at,from_state,to_state,note) VALUES(?,?,?,?,?)",
                 [p.id, now, old?.state.rawValue, p.state.rawValue, note])
    }
  }

  public func deletePost(_ id: String) throws {
    try db.run("DELETE FROM platform_posts WHERE id=?", [id])
    try db.run("INSERT INTO post_history(post_id,at,from_state,to_state,note) VALUES(?,?,?,?,?)", [id, now, nil, "deleted", nil])
  }

  public func history(postId: String) throws -> [PostHistoryEntry] {
    try db.query("SELECT * FROM post_history WHERE post_id=? ORDER BY id", [postId]).map {
      PostHistoryEntry(id: $0.int64("id")!, postId: $0.string("post_id")!, at: $0.date("at")!,
                       fromState: $0.string("from_state"), toState: $0.string("to_state")!, note: $0.string("note"))
    }
  }

  static func post(_ r: Row) -> PlatformPost {
    PlatformPost(id: r.string("id")!, videoId: r.string("video_id")!, platform: Platform(rawValue: r.string("platform")!)!,
                 versionNo: r.int("version_no")!, attemptNo: r.int("attempt_no")!,
                 kind: PostKind(rawValue: r.string("kind")!) ?? .regular, planSlotId: r.string("plan_slot_id"),
                 scheduledAt: r.date("scheduled_at")!, renderId: r.string("render_id"),
                 state: PostState(rawValue: r.string("state")!) ?? .planned, publisher: r.string("publisher")!,
                 externalId: r.string("external_id"), url: r.string("url"), postedAt: r.date("posted_at"),
                 errorType: r.string("error_type").flatMap(ErrorType.init), errorMessage: r.string("error_message"),
                 rawResponse: r.string("raw_response"), resolution: r.string("resolution"), metrics: r.json("metrics"),
                 createdAt: r.date("created_at")!, updatedAt: r.date("updated_at")!)
  }

  // MARK: Renders

  public func renders(where clause: String = "deleted_at IS NULL", _ binds: [SQLBindable?] = []) throws -> [Render] {
    try db.query("SELECT * FROM renders WHERE \(clause) ORDER BY created_at", binds).map(Self.render)
  }

  public func render(id: String) throws -> Render? {
    try db.one("SELECT * FROM renders WHERE id=?", [id]).map(Self.render)
  }

  public func save(_ r: Render) throws {
    try db.run("""
      INSERT INTO renders(id,video_id,version_no,edit_hash,scope,output_path,cover_path,loudness,duration,size,status,error,created_at,deleted_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET output_path=excluded.output_path, cover_path=excluded.cover_path, loudness=excluded.loudness,
        duration=excluded.duration, size=excluded.size, status=excluded.status, error=excluded.error, deleted_at=excluded.deleted_at
      """, [r.id, r.videoId, r.versionNo, r.editHash, r.scope, r.outputPath, r.coverPath,
            r.loudness.map { JSONCoding.string($0) }, r.duration, r.size, r.status.rawValue, r.error, r.createdAt, r.deletedAt])
  }

  static func render(_ r: Row) -> Render {
    Render(id: r.string("id")!, videoId: r.string("video_id")!, versionNo: r.int("version_no")!,
           editHash: r.string("edit_hash")!, scope: r.string("scope")!, outputPath: r.string("output_path"),
           coverPath: r.string("cover_path"), loudness: r.json("loudness"), duration: r.double("duration"),
           size: r.int64("size"), status: RenderStatus(rawValue: r.string("status")!) ?? .pending, error: r.string("error"),
           createdAt: r.date("created_at")!, deletedAt: r.date("deleted_at"))
  }

  // MARK: Events, heartbeats, notification dedupe

  public func logEvent(_ kind: String, _ message: String, videoId: String? = nil, postId: String? = nil) throws {
    try db.run("INSERT INTO events(at,kind,message,video_id,post_id) VALUES(?,?,?,?,?)", [now, kind, message, videoId, postId])
    Log.shared.info("[\(kind)] \(message)")
  }

  public func events(limit: Int = 200, videoId: String? = nil) throws -> [EventRecord] {
    let rows = try videoId.map { try db.query("SELECT * FROM events WHERE video_id=? ORDER BY id DESC LIMIT ?", [$0, limit]) }
      ?? db.query("SELECT * FROM events ORDER BY id DESC LIMIT ?", [limit])
    return rows.map {
      EventRecord(id: $0.int64("id")!, at: $0.date("at")!, kind: $0.string("kind")!, message: $0.string("message")!,
                  videoId: $0.string("video_id"), postId: $0.string("post_id"))
    }
  }

  public func heartbeat(_ kind: HeartbeatKind, at: Date? = nil) throws {
    try db.run("INSERT INTO heartbeats(at,kind) VALUES(?,?)", [at ?? now, kind.rawValue])
  }

  public func heartbeats(since: Date) throws -> [Heartbeat] {
    try db.query("SELECT * FROM heartbeats WHERE at>=? ORDER BY at", [since]).map {
      Heartbeat(at: $0.date("at")!, kind: HeartbeatKind(rawValue: $0.string("kind")!) ?? .tick)
    }
  }

  public func lastHeartbeat() throws -> Heartbeat? {
    try db.one("SELECT * FROM heartbeats ORDER BY at DESC LIMIT 1").map {
      Heartbeat(at: $0.date("at")!, kind: HeartbeatKind(rawValue: $0.string("kind")!) ?? .tick)
    }
  }

  /// Returns true the first time a key is seen (so each notification is sent once).
  public func markNotified(_ key: String) throws -> Bool {
    try db.run("INSERT OR IGNORE INTO sent_notifications(key,at) VALUES(?,?)", [key, now]) > 0
  }

  // MARK: Derived video state

  /// Recomputes a video's state from its flags, edit, versions and posts (spec §3 States).
  public func refreshState(videoId: String) throws {
    guard let v = try video(id: videoId) else { return }
    let s = try computeState(v)
    if s != v.state {
      try db.run("UPDATE videos SET state=?, updated_at=? WHERE id=?", [s.rawValue, now, videoId])
    }
  }

  /// The held flag counts only for a short clip with nothing posted (regular/retry).
  public func isHeld(_ v: Video) throws -> Bool {
    guard v.heldInEdit, v.type == .short else { return false }
    return try db.one("SELECT 1 AS x FROM platform_posts WHERE video_id=? AND kind IN ('regular','retry') AND state='posted'",
                      [v.id]) == nil
  }

  public func computeState(_ v: Video) throws -> VideoState {
    if v.missing { return .missingFile }
    if v.excluded { return .excluded }
    // Sent back from Queue: Edit until Eric sends it to the queue again (its future slots/posts were removed).
    // Never masks a clip that already posted somewhere (Remove from queue refuses those).
    if try isHeld(v) { return .needsEdit }
    // Latest attempt per platform; a retry (fix) supersedes the failed regular post. Reposts don't change state.
    let posts = try self.posts(where: "video_id=? AND kind IN ('regular','retry')", [v.id])
    if !posts.isEmpty {
      let st = try settings()
      let active = Set(st.activePlatforms)
      let latest = Dictionary(grouping: posts, by: \.platform).compactMapValues { $0.max { $0.attemptNo < $1.attemptNo } }
      let relevant = latest.filter { active.contains($0.key) }.map(\.value)
      if !relevant.isEmpty, relevant.allSatisfy({ $0.state.isTerminal }) {
        return relevant.allSatisfy { $0.state == .posted || $0.state == .skipped } ? .posted : .partial
      }
      if relevant.contains(where: { $0.state == .posted || $0.state == .due || $0.state == .overdue }) { return .posting }
      return .planned
    }
    if v.type == .long { return v.longformURL == nil ? .ready : .posted }
    // Planned = in an APPROVED week (spec §3); draft proposals don't count.
    let inApproved = try db.one(
      "SELECT 1 AS x FROM plan_slots s JOIN weeks w ON w.week_start=s.week_start AND w.state='approved' WHERE s.video_id=?",
      [v.id]) != nil
    if inApproved { return .planned }
    return try Validation.isReady(video: v, store: self) ? .ready : .needsEdit
  }
}

public enum VersionResolver {
  /// Carry-forward + defaults. With `video`, text that no version sets comes from `defaults.textSource`
  /// (Title / raw tag verbatim / empty) and talking clips get "No text" when `noTextForTalking` is on.
  public static func resolve(_ versions: [Version], number: Int, settings: Settings, video: Video? = nil) -> ResolvedVersion {
    let d = settings.defaults
    let chain = versions.filter { $0.number <= number }.sorted { $0.number < $1.number }
    var inherited = Set<String>()
    var defaulted = Set<String>()
    func pick<T>(_ key: String, _ kp: KeyPath<Version, T?>) -> T? {
      for v in chain.reversed() {
        if let x = v[keyPath: kp] {
          if let s = x as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
          if v.number != number { inherited.insert(key) }
          return x
        }
      }
      defaulted.insert(key)
      return nil
    }
    // Text and "No text" resolve as one field: the latest version that sets either decides both.
    var text = "", noText = false, decided = false
    for v in chain.reversed() {
      let t = v.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if v.noText == true || !t.isEmpty {
        text = v.text ?? ""
        noText = v.noText == true
        decided = true
        if v.number != number { inherited.insert("text"); inherited.insert("noText") }
        break
      }
      if v.noText == false, v.number == number { decided = true; break }  // explicitly cleared "No text"
    }
    if !decided {
      defaulted.insert("text"); defaulted.insert("noText")
      if let video {
        if video.kind == .talking && d.noTextForTalking {
          noText = true
        } else {
          switch d.textSource {
          case .title: text = video.titleText ?? ""
          case .rawTag: text = video.type == .short ? video.tag : ""
          case .empty: text = ""
          }
        }
      }
    }
    let start = pick("textStart", \.textStart), end = pick("textEnd", \.textEnd)
    let timingDefault = defaulted.contains("textStart") && defaulted.contains("textEnd")
    return ResolvedVersion(
      number: number,
      text: text,
      noText: noText,
      style: pick("style", \.style) ?? d.textStyle,
      size: pick("size", \.size) ?? d.textSize,
      posX: pick("posX", \.posX) ?? d.textPosX,
      posY: pick("posY", \.posY) ?? d.textPosY,
      align: pick("align", \.align) ?? d.textAlign,
      textStart: timingDefault ? d.textWindow.start : start,
      textEnd: timingDefault ? d.textWindow.end : end,
      caption: pick("caption", \.caption) ?? "",
      captionTemplateId: pick("captionTemplateId", \.captionTemplateId),
      hashtagSetIds: pick("hashtagSetIds", \.hashtagSetIds) ?? d.hashtagSetIds,
      extraHashtags: pick("extraHashtags", \.extraHashtags) ?? d.extraHashtags,
      youtubeTitle: pick("youtubeTitle", \.youtubeTitle) ?? "",
      platformCaptions: pick("platformCaptions", \.platformCaptions) ?? [:],
      inherited: inherited,
      defaulted: defaulted)
  }
}

public func newId() -> String { UUID().uuidString.lowercased() }

public enum StoreError: Error, CustomStringConvertible {
  case corruptRow(String, String)
  public var description: String {
    switch self {
    case .corruptRow(let table, let key): "Unreadable \(table) row \(key) — left untouched; see Doctor"
    }
  }
}
