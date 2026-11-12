import Foundation

/// The app's database (spec §3): single source of truth for everything that changes.
/// The GUI, the engine and the `djq` CLI all open the same file (WAL).
public final class Store: @unchecked Sendable {
  public let db: SQLite
  public let paths: Paths
  public let clock: Clock

  public static let schemaVersion = 11
  /// Schema step that adds `videos.sent_to_queue` (`migrateSentToQueue`). `schemaVersion` stays a literal: build-app.sh
  /// reads the number from that line into the bundle, and `djq autoupdate rollback` relies on it.
  static let sentToQueueVersion = 8

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
    if v < 4 { try migrateToV4(from: v) }
    if v < 5 { try migrateToV5(from: v) }
    // Before the v6 step: its journal entry snapshots clips, and those snapshots read the flag.
    if v < Self.sentToQueueVersion { try migrateSentToQueue(from: v) }
    if v < 6 { try migrateToV6(from: v) }
    if v < 7 { try migrateToV7(from: v) }
    if v < Self.sentToQueueVersion { try db.exec("PRAGMA user_version = \(Self.sentToQueueVersion)") }
    if v < 9 { try migrateToV9(from: v) }
    if v < 10 { try migrateToV10(from: v) }
    if v < 11 { try migrateToV11(from: v) }
    // Idempotent additions to v2 (dev databases created before they existed).
    let bcols = Set(try db.query("PRAGMA table_info(batches)").compactMap { $0.string("name") })
    if !bcols.contains("restored") { try db.exec("ALTER TABLE batches ADD COLUMN restored TEXT NOT NULL DEFAULT '[]'") }
    let jcols = Set(try db.query("PRAGMA table_info(postiz_jobs)").compactMap { $0.string("name") })
    if !jcols.isEmpty, !jcols.contains("lineage") {
      try db.exec("ALTER TABLE postiz_jobs ADD COLUMN lineage TEXT NOT NULL DEFAULT ''; CREATE INDEX IF NOT EXISTS postiz_jobs_lineage ON postiz_jobs(lineage)")
    }
    if !jcols.isEmpty, !jcols.contains("content") { try db.exec("ALTER TABLE postiz_jobs ADD COLUMN content TEXT NOT NULL DEFAULT ''") }
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

  /// Round 13 (A11): the only way into the Queue is Eric's Send to Queue, so a clip now carries that as a fact. Additive
  /// and lossless: no state changes here. A clip with a day or posts counts as sent. A `ready` clip counts only with proof:
  /// a score, and a "Sent to Queue" event that no "Sent back" or "Moved to Edit" follows; round 4 also put clips in the Queue
  /// by themselves, and the scheduler would post those. Without proof it waits in Edit, which fails safe. A file database with data is copied to
  /// `<app support>/backups/` first. `migrate` writes the version.
  private func migrateSentToQueue(from v: Int) throws {
    if v >= 1, db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM videos")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-sent-to-queue-\(f.string(from: Date())).sqlite").path)
    }
    try db.transaction {
      let cols = Set(try db.query("PRAGMA table_info(videos)").compactMap { $0.string("name") })
      if !cols.contains("sent_to_queue") {
        try db.exec("ALTER TABLE videos ADD COLUMN sent_to_queue INTEGER NOT NULL DEFAULT 0")
      }
      try db.exec("""
        UPDATE videos SET sent_to_queue=1 WHERE type='short-form'
          AND (state IN ('planned','posting','posted','partial') OR (state='ready' AND score IS NOT NULL AND EXISTS(
            SELECT 1 FROM events sent WHERE sent.video_id=videos.id AND sent.kind='queue' AND sent.message='Sent to Queue'
              AND NOT EXISTS(SELECT 1 FROM events out WHERE out.video_id=videos.id AND out.id>sent.id
                             AND ((out.kind='queue' AND out.message='Sent back to Edit from Queue')
                                  OR (out.kind='stage' AND out.message LIKE 'Moved to Edit%'))))))
        """)
    }
  }

  /// Overlay-text suggestions (round 5): a new table shaped like `title_suggestions`. Additive and lossless (no
  /// existing row changes). A file database with data is copied to `<app support>/backups/` first.
  private func migrateToV4(from v: Int) throws {
    if v >= 3, db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM videos")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-schema4-\(f.string(from: Date())).sqlite").path)
    }
    try db.transaction {
      try db.exec("""
        CREATE TABLE IF NOT EXISTS text_suggestions(id INTEGER PRIMARY KEY AUTOINCREMENT,
          video_id TEXT NOT NULL REFERENCES videos(id), text TEXT NOT NULL, tracks TEXT NOT NULL DEFAULT '[]',
          confidence REAL, source TEXT NOT NULL DEFAULT '', origin TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL, UNIQUE(video_id, origin, text, source));
        CREATE INDEX IF NOT EXISTS text_suggestions_video ON text_suggestions(video_id);
        PRAGMA user_version = 4;
        """)
    }
  }

  /// Postiz publisher (round 6): `postiz_jobs` (one row per Postiz post DJ Queue made) and `postiz_media` (uploaded
  /// media per render). Additive and lossless (no existing row changes). No foreign key to platform_posts: the
  /// planner may delete a post and its job must survive so the engine can cancel it in Postiz. A file database with
  /// data is copied to `<app support>/backups/` first.
  private func migrateToV5(from v: Int) throws {
    if v >= 4, db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM videos")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-schema5-\(f.string(from: Date())).sqlite").path)
    }
    try db.transaction {
      try db.exec(Self.postizSchema + "\nPRAGMA user_version = 5;")
    }
  }

  /// Hashtag groups become Eric's own (round 7, `HashtagGroupsMigration`): post clips keep byte-identical captions,
  /// the six built-in groups go, the default is no groups, a written caption is literal. The data part is one journaled
  /// batch (`djq bulk undo`). A new database has nothing to migrate. A file database with data is copied to
  /// `<app support>/backups/` first.
  private func migrateToV6(from v: Int) throws {
    guard v >= 1 else { try db.exec("PRAGMA user_version = 6"); return }
    if db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM videos")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-schema6-\(f.string(from: Date())).sqlite").path)
    }
    let r = try HashtagGroupsMigration.run(self)
    Log.shared.info("schema 6: hashtag groups — \(r.frozen.count) clip(s) with posts frozen, \(r.dropped.count) dropped built-in groups, \(r.suffixed) written caption(s) kept their hashtags, batch \(r.batchId ?? "none")")
  }

  /// v0.8.3 changes how captions are built (`CaptionRulesMigration`): clips with posts keep byte-identical captions.
  private func migrateToV7(from v: Int) throws {
    guard v >= 1 else { try db.exec("PRAGMA user_version = 7"); return }
    let held = try CaptionRulesMigration.run(self)
    Log.shared.info("schema 7: caption rules — \(held.count) clip(s) with posts kept their captions")
  }

  /// Round 21, photo posts and set-time posts: `videos.photos` (a photo post's photos, NULL for every video),
  /// `plan_slots.exact_at` (a set-time slot's moment, NULL for every regular slot) and `renders.more_paths` (a photo
  /// render's files after the first). Additive and lossless: three nullable columns, no existing row changes. A file
  /// database with data is copied to `<app support>/backups/` first.
  private func migrateToV9(from v: Int) throws {
    if v >= 1, db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM videos")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-schema9-\(f.string(from: Date())).sqlite").path)
    }
    try db.transaction {
      for (table, column, type) in [("videos", "photos", "TEXT"), ("plan_slots", "exact_at", "REAL"), ("renders", "more_paths", "TEXT")] {
        let cols = Set(try db.query("PRAGMA table_info(\(table))").compactMap { $0.string("name") })
        if !cols.contains(column) { try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
      }
      try db.exec("PRAGMA user_version = 9")
    }
  }

  /// Round 23, photo with audio: `videos.still` (what a made video was made from, NULL for every other row). Additive
  /// and lossless: one nullable column, no existing row changes. A file database with data is copied to
  /// `<app support>/backups/` first.
  private func migrateToV10(from v: Int) throws {
    if v >= 1, db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM videos")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-schema10-\(f.string(from: Date())).sqlite").path)
    }
    try db.transaction {
      let cols = Set(try db.query("PRAGMA table_info(videos)").compactMap { $0.string("name") })
      if !cols.contains("still") { try db.exec("ALTER TABLE videos ADD COLUMN still TEXT") }
      try db.exec("PRAGMA user_version = 10")
    }
  }

  /// Round 27 (Eric: a new version is its own). Every v2 and later stops following earlier versions: what it took from
  /// them is copied in, it is marked `standalone`, and copied texts get their own ids. Nothing any version shows
  /// changes: each one's resolved content (texts, look, timing, captions) and so its render and caption hashes stay
  /// the same, and a clip whose content would change is left as it was and logged. One journaled batch
  /// (`djq bulk undo` restores it). A file database with data is copied to `<app support>/backups/` first. A new
  /// database has nothing to migrate.
  private func migrateToV11(from v: Int) throws {
    guard v >= 1 else { try db.exec("PRAGMA user_version = 11"); return }
    if db.path != ":memory:", (try db.one("SELECT COUNT(*) AS n FROM versions WHERE number > 1")?.int("n") ?? 0) > 0 {
      let dir = paths.appSupport.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.dateFormat = "yyyyMMdd-HHmmss"
      try db.backup(to: dir.appendingPathComponent("queue-before-schema11-\(f.string(from: Date())).sqlite").path)
    }
    let r = try VersionSeparationMigration.run(self)
    Log.shared.info("schema 11: separate versions — \(r.versions) version(s) on \(r.clips.count) clip(s) stand alone, \(r.leftAsIs.count) clip(s) left as they were, batch \(r.batchId ?? "none")")
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
    return Self.decodeSettings(s)
  }

  /// A stored settings row decoded exactly as `settings()` does (lenient, migrations applied in memory).
  public static func decodeSettings(_ s: String) -> Settings {
    do {
      // A top-level field of the wrong type would fail the whole decode: drop just that field (it takes its default).
      var raw = Data(s.utf8)
      if var o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
        var changed = false
        if let p = o["publishing"], !(p is [String: Any]) { o.removeValue(forKey: "publishing"); changed = true }
        if let r = o["limitsRevision"], !(r is NSNumber) || CFGetTypeID(r as CFTypeRef) == CFBooleanGetTypeID() {
          o.removeValue(forKey: "limitsRevision"); changed = true
        }
        if changed, let d = try? JSONSerialization.data(withJSONObject: o) { raw = d }
      }
      var out = try JSONCoding.decodeLenient(raw, defaults: Settings())
      // Round-1 rows kept the text/caption defaults at the top level: carry them into `defaults` once.
      if let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any], obj["defaults"] == nil {
        if let x = (obj["defaultStyle"] as? String).flatMap(TextStyle.init) { out.defaults.textStyle = x }
        if let x = obj["defaultTextSize"] as? Double { out.defaults.textSize = x }
        if let x = obj["defaultPosY"] as? Double { out.defaults.textPosY = x }
        if let x = obj["defaultCaptionTemplateId"] as? String { out.defaults.captionTemplateId = x }
        if let x = obj["defaultHashtagSetIds"] as? [String] { out.defaults.hashtagSetIds = x }
      }
      // Round 7: a row from before YouTube title templates: its single template becomes the one entry (same id as
      // the seeded default, so `defaults.youtubeTitleTemplateId` finds it).
      if let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any], o["youtubeTitleTemplates"] == nil {
        let t = out.defaults.youtubeTitleTemplate
        let seed = Defaults.youtubeTitleTemplates[0]
        out.youtubeTitleTemplates = [TitleTemplate(id: seed.id, name: t == seed.template ? seed.name : t, template: t)]
        out.defaults.youtubeTitleTemplateId = seed.id
      }
      // Round 6: limits stored against an older `PlatformLimits.defaults` move only where they still equal the old
      // default (in memory; the next save writes them with the current revision).
      let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
      let rev = (obj?["limitsRevision"] as? Int) ?? 1
      if rev < PlatformLimits.revision {
        out.limits = PlatformLimits.migrateStored(out.limits, from: rev)
        out.limitsRevision = PlatformLimits.revision
      }
      return out
    } catch {
      Log.shared.error("settings unreadable, using defaults in memory: \(error)")
      return Settings()
    }
  }
  /// Round 7: `defaults.youtubeTitleTemplate` is written as the default template's text, so an older build (or a
  /// rollback) reading this row gets the same title.
  public func save(_ s: Settings) throws {
    var s = s
    s.defaults.youtubeTitleTemplate = s.youtubeTitleTemplate(id: s.defaults.youtubeTitleTemplateId)
    try setKV("settings", s)
  }

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
        held_in_edit,sent_to_queue,photos,still)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id, name=excluded.name, tags=excluded.tags,
        type=excluded.type, content_type=excluded.content_type, kind=excluded.kind, file=excluded.file,
        fingerprint=excluded.fingerprint, file_size=excluded.file_size, duration=excluded.duration,
        marked_start=excluded.marked_start, marked_end=excluded.marked_end, start=excluded.start, "end"=excluded."end",
        grace=excluded.grace, audio=excluded.audio, part=excluded.part, score=excluded.score, state=excluded.state,
        excluded=excluded.excluded, missing=excluded.missing, in_manifest=excluded.in_manifest, notes=excluded.notes,
        already_posted_on=excluded.already_posted_on, longform_url=excluded.longform_url, updated_at=excluded.updated_at,
        title=excluded.title, title_tracks=excluded.title_tracks, title_source=excluded.title_source,
        source_width=excluded.source_width, source_height=excluded.source_height, held_in_edit=excluded.held_in_edit,
        sent_to_queue=excluded.sent_to_queue, photos=excluded.photos, still=excluded.still
      """, [v.id, v.sessionId, v.name, JSONCoding.string(v.tags), v.type.rawValue, v.contentType, v.kind.rawValue,
            v.file, v.fingerprint, v.fileSize, v.duration, v.markedStart, v.markedEnd, v.start, v.end, v.grace,
            v.audio, v.part, v.score, v.state.rawValue, v.excluded, v.missing, v.inManifest, v.notes,
            JSONCoding.string(v.alreadyPostedOn), v.longformURL, v.createdAt, v.updatedAt, v.title,
            v.titleTracks.map { JSONCoding.string($0) }, v.titleSource, v.sourceWidth, v.sourceHeight, v.heldInEdit,
            v.sentToQueue, v.photos.map { JSONCoding.string($0) }, v.still.map { JSONCoding.string($0) }])
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

  /// Clearing a score takes the clip back past Edit: it has to be sent again. A photo post needs no score (round 21),
  /// nor does a video made from a photo (round 23), so clearing its score leaves it where it is.
  public func setScore(_ id: String, _ score: Int?) throws {
    try db.run("UPDATE videos SET score=?, sent_to_queue=CASE WHEN ? AND NOT \(Self.noScoreSQL) THEN 0 ELSE sent_to_queue END, updated_at=? WHERE id=?",
               [score.map { min(100, max(0, $0)) }, score == nil, now, id])
    try logEvent("score", "Score \(score.map(String.init) ?? "cleared")", videoId: id)
  }

  /// Excluding takes the clip out of the pipeline; including it again doesn't put it back in the Queue.
  public func setExcluded(_ id: String, _ excluded: Bool) throws {
    try db.run("UPDATE videos SET excluded=?, sent_to_queue=CASE WHEN ? THEN 0 ELSE sent_to_queue END, updated_at=? WHERE id=?",
               [excluded, excluded, now, id])
    try refreshState(videoId: id)
  }

  public func setKind(_ id: String, _ kind: Kind) throws {
    try db.run("UPDATE videos SET kind=?, updated_at=? WHERE id=?", [kind.rawValue, now, id])
    try refreshState(videoId: id)  // "No text for Talking" can change readiness
  }

  /// "Back to Edit": while held, the clip stays in Edit with the issue "Sent back from Queue", and it is no longer sent.
  /// Clearing the flag doesn't send it (`setSentToQueue` does). Plan slots and posts are not touched here —
  /// `BulkActions.removeFromQueue` does that with the planner's rules.
  public func setHeldInEdit(_ id: String, _ held: Bool) throws {
    try db.run("UPDATE videos SET held_in_edit=?, sent_to_queue=CASE WHEN ? THEN 0 ELSE sent_to_queue END, updated_at=? WHERE id=?",
               [held, held, now, id])
    if held { try logEvent("queue", "Sent back to Edit from Queue", videoId: id) }
    try refreshState(videoId: id)
  }

  /// Round 13 (A11): Eric's Send to Queue. Only `BulkActions.send` sets it; nothing else ever moves a clip Edit → Queue.
  func setSentToQueue(_ id: String, _ sent: Bool) throws {
    try db.run("UPDATE videos SET sent_to_queue=?, updated_at=? WHERE id=?", [sent, now, id])
    if sent { try logEvent("queue", "Sent to Queue", videoId: id) }
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
          sourceWidth: r.int("source_width"), sourceHeight: r.int("source_height"), heldInEdit: r.bool("held_in_edit"),
          sentToQueue: r.bool("sent_to_queue"), photos: r.json("photos"), still: r.json("still"))
  }

  /// SQL for `Video.needsNoScore`: a photo post, or a video made from a photo (round 23).
  static let noScoreSQL = "(photos IS NOT NULL OR still IS NOT NULL)"

  public func fileURL(for v: Video) throws -> URL? {
    // Round 21: always this store's Photos folder. Round 23: a made video lives there too (`Stills/<id>/video.mp4`).
    if v.isPhoto || v.isStill { return paths.photos.appendingPathComponent(v.file) }
    if v.file.hasPrefix("/") { return URL(fileURLWithPath: v.file) }  // relinked into another session's folder
    guard let s = try session(id: v.sessionId) else { return nil }
    return URL(fileURLWithPath: s.folder).appendingPathComponent(v.file)
  }

  // MARK: Edits and versions

  /// The video's edit (default `Edit()` when none saved). Keys missing from older JSON keep their defaults;
  /// unreadable JSON throws rather than silently dropping the crop.
  ///
  /// Round 21 (D8): a photo post's edit always skips the platforms that take no photos (YouTube Shorts), whatever the
  /// stored row says, so nothing that reads an edit can plan or post one there.
  public func edit(videoId: String) throws -> Edit {
    let row = try db.one("""
      SELECT (SELECT json FROM edits WHERE video_id=?) AS json, (SELECT photos IS NOT NULL FROM videos WHERE id=?) AS photo
      """, [videoId, videoId])
    var e = try row?.string("json").map { try JSONCoding.decodeLenient(Data($0.utf8), defaults: Edit()) } ?? Edit()
    if row?.bool("photo") == true { Self.keepPhotoPlatforms(&e) }
    return e
  }

  /// A photo post never posts where photos can't go: those platforms are skipped and can't be turned on.
  static func keepPhotoPlatforms(_ e: inout Edit) {
    for p in Platform.allCases where !p.supportsPhotos {
      e.skippedPlatforms.insert(p)
      e.includedPlatforms.remove(p)
    }
  }

  public func hasEdit(videoId: String) throws -> Bool {
    try db.one("SELECT 1 AS x FROM edits WHERE video_id=?", [videoId]) != nil
  }

  /// `remembersCrop`: this crop becomes "last crop" for the `.lastUsed` anchor. A bulk pass isn't one crop Eric chose for the next clip.
  /// A photo post's edit is stored with its no-photo platforms skipped (round 21, D8), and its crops never become "last crop".
  public func save(_ e: Edit, videoId: String, remembersCrop: Bool = true) throws {
    var e = e
    let kind = try db.one("SELECT photos IS NOT NULL AS photo, still IS NOT NULL AS still FROM videos WHERE id=?", [videoId])
    let isPhoto = kind?.bool("photo") == true
    if isPhoto { Self.keepPhotoPlatforms(&e) }
    // Round 23: a made video's crop isn't "last crop" either: its picture is a photo of any shape, not the camera's frame.
    if remembersCrop, !isPhoto, kind?.bool("still") != true, let c = e.crop, let v = try video(id: videoId), let w = v.sourceWidth, let h = v.sourceHeight, w > 0, h > 0,
       try edit(videoId: videoId).crop != c {
      struct P: Codable { var x: Double; var y: Double }
      try setKV("defaults.lastCropCentre", P(x: (c.x + c.w / 2) / Double(w), y: (c.y + c.h / 2) / Double(h)))
    }
    // Round 24: a change to markers alone keeps `updated_at`, so the lists don't rebuild a preview nothing in changed.
    let marksOnly = (try? edit(videoId: videoId)).map { e.differsOnlyInMarks(from: $0) } ?? false
    try db.run("INSERT INTO edits(video_id,json,updated_at) VALUES(?,?,?) ON CONFLICT(video_id) DO UPDATE SET json=excluded.json, "
               + "updated_at=CASE WHEN ? THEN edits.updated_at ELSE excluded.updated_at END",
               [videoId, JSONCoding.string(e), now, marksOnly ? 1 : 0])
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
    // Round 27: a v2 or later is always written standing alone. One that still follows earlier versions (made by a path
    // that predates it, or restored from an old journal) first gets what it shows now copied in, so nothing it shows
    // changes, and from then on no edit to another version reaches it.
    var v = v
    // An unreadable sibling row (Doctor reports it) never blocks the save: the version is then saved as given.
    if v.number > 1, v.standalone != true, let others = try? versions(videoId: videoId).filter({ $0.number != v.number }) {
      v = VersionCopy.standingAlone(v, in: others + [v], settings: try settings())
    }
    try db.run("INSERT INTO versions(video_id,number,json,updated_at) VALUES(?,?,?,?) ON CONFLICT(video_id,number) DO UPDATE SET json=excluded.json, updated_at=excluded.updated_at",
               [videoId, v.number, JSONCoding.string(v), now])
    try refreshState(videoId: videoId)
  }

  public func deleteVersion(videoId: String, number: Int) throws {
    try db.run("DELETE FROM versions WHERE video_id=? AND number=?", [videoId, number])
    try refreshState(videoId: videoId)
  }

  /// Resolution of version `number` (spec §3): empty fields inherit from earlier versions, up to the latest one that
  /// stands alone (round 27: every v2+ does), and otherwise follow the defaults.
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
               videoId: $0.string("video_id")!, pinned: $0.bool("pinned"), weekStart: $0.string("week_start")!,
               exactAt: $0.date("exact_at"))
    }
  }

  public func save(_ s: PlanSlot) throws {
    try db.run("INSERT INTO plan_slots(id,date,position,video_id,pinned,week_start,exact_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET date=excluded.date, position=excluded.position, video_id=excluded.video_id, pinned=excluded.pinned, week_start=excluded.week_start, exact_at=excluded.exact_at",
               [s.id, s.date, s.position, s.videoId, s.pinned, s.weekStart, s.exactAt])
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
      INSERT INTO renders(id,video_id,version_no,edit_hash,scope,output_path,cover_path,loudness,duration,size,status,error,created_at,deleted_at,more_paths)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET output_path=excluded.output_path, cover_path=excluded.cover_path, loudness=excluded.loudness,
        duration=excluded.duration, size=excluded.size, status=excluded.status, error=excluded.error, deleted_at=excluded.deleted_at,
        more_paths=excluded.more_paths
      """, [r.id, r.videoId, r.versionNo, r.editHash, r.scope, r.outputPath, r.coverPath,
            r.loudness.map { JSONCoding.string($0) }, r.duration, r.size, r.status.rawValue, r.error, r.createdAt, r.deletedAt,
            r.morePaths.map { JSONCoding.pathList($0) }])
  }

  static func render(_ r: Row) -> Render {
    var out = Render(id: r.string("id")!, videoId: r.string("video_id")!, versionNo: r.int("version_no")!,
           editHash: r.string("edit_hash")!, scope: r.string("scope")!, outputPath: r.string("output_path"),
           coverPath: r.string("cover_path"), loudness: r.json("loudness"), duration: r.double("duration"),
           size: r.int64("size"), status: RenderStatus(rawValue: r.string("status")!) ?? .pending, error: r.string("error"),
           createdAt: r.date("created_at")!, deletedAt: r.date("deleted_at"))
    out.morePaths = r.json("more_paths")
    return out
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

  /// The notification with this key went out.
  public func wasNotified(_ key: String) throws -> Bool {
    try db.one("SELECT 1 AS x FROM sent_notifications WHERE key=?", [key]) != nil
  }

  /// Forgets a notification, so its key can go out again.
  public func clearNotified(_ key: String) throws { try db.run("DELETE FROM sent_notifications WHERE key=?", [key]) }

  // MARK: Derived video state

  /// Recomputes a video's state from its flags, edit, versions and posts (spec §3 States).
  public func refreshState(videoId: String) throws {
    guard let v = try video(id: videoId) else { return }
    try refreshState(v, context: nil)
  }

  /// Recomputes and stores `v`'s state; returns the new state when it changed (nil = unchanged). Round 4 (S1): when
  /// a Queue clip (stored `ready`) lands in Edit for any reason other than being sent back, logs a "stage" event
  /// "Moved to Edit: No crop · Too long for X" — the same words as its reason chips.
  @discardableResult
  public func refreshState(_ v: Video, context: ValidationContext?) throws -> VideoState? {
    let s = try computeState(v, context: context)
    // Round 13 (A11): a sent clip that lands in Edit isn't sent any more, so fixing it later never promotes it.
    if v.sentToQueue, s == .needsEdit || s == .missingFile {
      try db.run("UPDATE videos SET sent_to_queue=0, updated_at=? WHERE id=?", [now, v.id])
    }
    guard s != v.state else { return nil }
    try db.run("UPDATE videos SET state=?, updated_at=? WHERE id=?", [s.rawValue, now, v.id])
    var after = v
    after.state = s
    if Self.wasInQueue(v), ClipStage.of(after) == .edit {
      let issues = try Validation.issues(video: after, store: self, context: context)
      // "Back to Edit" logs its own event, and a clip with no issues just wasn't sent: no reason to give.
      if !issues.isEmpty, !issues.contains(where: { $0.kind == .heldInEdit }) {
        // A clip pinned to a (draft) day stays on that day: say it can't post there, not that it moved.
        let dm = try dayMath()
        if let pin = try planSlots(where: "video_id=? AND pinned=1 AND date>=?", [v.id, today(dm)]).first {
          let s = try context?.settings ?? settings()
          try logEvent("stage", StageWording.cantPost(on: BulkActions.day(pin.date, dm, s), issues), videoId: v.id)
        } else {
          try logEvent("stage", StageWording.movedToEdit(issues), videoId: v.id)
        }
      }
    }
    return s
  }

  /// The stored state says Queue (ready, scored, short, included) — the file flag aside, since intake sets
  /// `missing` before the state catches up.
  static func wasInQueue(_ v: Video) -> Bool {
    v.state == .ready && v.type == .short && !v.excluded && (v.score != nil || v.needsNoScore)
  }

  /// The held flag counts only for a short clip with nothing posted (regular/retry).
  public func isHeld(_ v: Video) throws -> Bool {
    guard v.heldInEdit, v.type == .short else { return false }
    return try db.one("SELECT 1 AS x FROM platform_posts WHERE video_id=? AND kind IN ('regular','retry') AND state='posted'",
                      [v.id]) == nil
  }

  public func computeState(_ v: Video) throws -> VideoState { try computeState(v, context: nil) }

  /// `computeState` with settings/templates/sets read once (`Revalidation` passes one context for every clip).
  public func computeState(_ v: Video, context: ValidationContext?) throws -> VideoState {
    if v.missing {
      // Round 4 (S1): a short clip whose file went missing after it was scheduled or posted keeps that state (it
      // stays in Scheduled/Posted and shows "File missing"); otherwise it is `missing_file` (stage Edit when scored).
      if !v.excluded, v.type == .short, let s = try planOrPostState(v, settings: context?.settings) { return s }
      return .missingFile
    }
    if v.excluded { return .excluded }
    // Sent back from Queue: Edit until Eric sends it to the queue again (its future slots/posts were removed).
    // Never masks a clip that already posted somewhere (Remove from queue refuses those).
    if try isHeld(v) { return .needsEdit }
    if let s = try planOrPostState(v, settings: context?.settings) { return s }
    if v.type == .long { return v.longformURL == nil ? .ready : .posted }
    // Round 13 (A11, reverses round 4's "stage = readiness"): valid isn't enough, the Queue takes only what Eric sent.
    guard v.sentToQueue else { return .needsEdit }
    return try Validation.isReady(video: v, store: self, context: context) ? .ready : .needsEdit
  }

  /// The state that comes from posts (posted / partial / posting / planned) or an approved-week slot (planned);
  /// nil when the clip is in neither.
  func planOrPostState(_ v: Video, settings: Settings? = nil) throws -> VideoState? {
    // Latest attempt per platform; a retry (fix) supersedes the failed regular post. Reposts don't change state.
    let posts = try self.posts(where: "video_id=? AND kind IN ('regular','retry')", [v.id])
    if !posts.isEmpty {
      let st = try settings ?? self.settings()
      let active = Set(st.activePlatforms)
      let latest = Dictionary(grouping: posts, by: \.platform).compactMapValues { $0.max { $0.attemptNo < $1.attemptNo } }
      let relevant = latest.filter { active.contains($0.key) }.map(\.value)
      // A failure with a retry coming isn't finished, whatever its row says.
      if !relevant.isEmpty, try relevant.allSatisfy({ try $0.state.isTerminal && !retryIsComing($0) }) {
        return relevant.allSatisfy { $0.state == .posted || $0.state == .skipped } ? .posted : .partial
      }
      if relevant.contains(where: { $0.state == .posted || $0.state == .due || $0.state == .overdue }) { return .posting }
      return .planned
    }
    if v.type == .long { return nil }
    // Planned = in an APPROVED week (spec §3); draft proposals don't count.
    let inApproved = try db.one(
      "SELECT 1 AS x FROM plan_slots s JOIN weeks w ON w.week_start=s.week_start AND w.state='approved' WHERE s.video_id=?",
      [v.id]) != nil
    return inApproved ? .planned : nil
  }
}

public enum VersionResolver {
  /// Carry-forward + defaults. With `video`, text that no version sets comes from `defaults.textSource`
  /// (Title / raw tag verbatim / empty) and talking clips get "No text" when `noTextForTalking` is on.
  public static func resolve(_ versions: [Version], number: Int, settings: Settings, video: Video? = nil) -> ResolvedVersion {
    let d = settings.defaults
    // Round 27: a version that stands alone (`standalone`) starts the chain: nothing before it carries into it or into
    // the versions after it.
    let upTo = versions.filter { $0.number <= number }.sorted { $0.number < $1.number }
    let cut = upTo.last { $0.standalone == true }?.number ?? Int.min
    let chain = upTo.filter { $0.number >= cut }
    var inherited = Set<String>()
    var defaulted = Set<String>()
    // Round 20: a version that keeps its own caption (`captionsOwn`, set when a bulk caption change on v1 must not reach
    // it) inherits caption fields from itself and later versions only; what it doesn't set follows the defaults.
    let captionCut = chain.last { $0.captionsOwn == true }?.number ?? Int.min
    let captionChain = chain.filter { $0.number >= captionCut }
    func pick<T>(_ key: String, _ kp: KeyPath<Version, T?>, captions: Bool = false) -> T? {
      for v in (captions ? captionChain : chain).reversed() {
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
      // Explicitly cleared "No text": what was typed stays, even when it's only spaces or empty lines (round 25: a
      // Return in an emptied box brought the Title back into it).
      if v.noText == false, v.number == number { text = v.text ?? ""; decided = true; break }
    }
    if !decided {
      defaulted.insert("text"); defaulted.insert("noText")
      if let video {
        if video.isPhoto || video.isStill {
          // Round 21 (D7): a photo post starts with no text. Texts added after the first still draw. Round 23 (D7): the
          // same for a video made from a photo (a flyer carries its own words).
          noText = !(chain.last { $0.moreText != nil }?.moreText ?? []).contains { !$0.isBlank }
        } else if video.kind == .talking && d.noTextForTalking {
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
    // Round 21 (D7): the default timing is in seconds ("First 3 seconds"). On a photo post a window counts photos, so
    // the default there is no window: the text shows on every photo.
    // Round 23 (D2): on a video made from a photo a text shows for the whole clip until Eric times it.
    let defaultWindow: (start: Double?, end: Double?) = video.map { $0.isPhoto || $0.isStill } == true ? (nil, nil) : d.textWindow
    var r = ResolvedVersion(
      number: number,
      text: text,
      noText: noText,
      style: pick("style", \.style) ?? d.textStyle,
      size: pick("size", \.size) ?? d.textSize,
      posX: pick("posX", \.posX) ?? d.textPosX,
      posY: pick("posY", \.posY) ?? d.textPosY,
      align: pick("align", \.align) ?? d.textAlign,
      textStart: timingDefault ? defaultWindow.start : start,
      textEnd: timingDefault ? defaultWindow.end : end,
      caption: pick("caption", \.caption, captions: true) ?? "",
      captionTemplateId: pick("captionTemplateId", \.captionTemplateId, captions: true),
      hashtagSetIds: pick("hashtagSetIds", \.hashtagSetIds, captions: true) ?? d.hashtagSetIds,
      extraHashtags: pick("extraHashtags", \.extraHashtags, captions: true) ?? d.extraHashtags,
      youtubeTitle: pick("youtubeTitle", \.youtubeTitle, captions: true) ?? "",
      platformCaptions: pick("platformCaptions", \.platformCaptions, captions: true) ?? [:],
      inherited: inherited,
      defaulted: defaulted)
    // Round 7: a chosen YouTube title template that no longer exists follows the default one.
    let yt = pick("youtubeTitleTemplateId", \.youtubeTitleTemplateId, captions: true)
    r.youtubeTitleTemplateId = yt
    r.youtubeTitleTemplate = settings.youtubeTitleTemplate(id: yt)
    // Round 16: carried like the rest, but a clip without them leaves `defaulted` and the resolved JSON as they were.
    func carried<T>(_ key: String, _ kp: KeyPath<Version, T?>) -> T? {
      guard let v = chain.last(where: { $0[keyPath: kp] != nil }) else { return nil }
      if v.number != number { inherited.insert(key) }
      return v[keyPath: kp]
    }
    r.moreText = (carried("moreText", \.moreText) ?? []).map { l in
      var l = l
      l.look = l.look?.normalized
      return l
    }
    r.textLook = carried("textLook", \.textLook)?.normalized
    r.inherited = inherited
    r.defaulted = defaulted
    return r
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
