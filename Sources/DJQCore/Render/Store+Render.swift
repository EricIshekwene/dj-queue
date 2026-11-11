import Foundation

/// Column-scoped render updates. Use these instead of `save(Render)` once a row exists, so two
/// writers (renderer, engine, CLI) never overwrite each other's columns with a stale snapshot.
extension Store {
  /// Sets status (and error text; nil clears it).
  public func setRenderStatus(id: String, status: RenderStatus, error: String? = nil) throws {
    try db.run("UPDATE renders SET status=?, error=? WHERE id=?", [status.rawValue, error, id])
  }

  /// Points a render at its files' current location (the engine calls this after moving a posted
  /// render to `Posted/Shortform/`, so the render keeps being reused instead of re-rendered).
  public func setRenderOutput(id: String, outputPath: String?, coverPath: String?) throws {
    try db.run("UPDATE renders SET output_path=?, cover_path=? WHERE id=?", [outputPath, coverPath, id])
  }

  /// A photo render's files after the first (round 21), at their current location. nil = none (a video).
  public func setRenderMorePaths(id: String, _ paths: [String]?) throws {
    try db.run("UPDATE renders SET more_paths=? WHERE id=?", [paths.map { JSONCoding.pathList($0) }, id])
  }

  /// Marks a render deleted (sets `deleted_at` only; files are the caller's business).
  public func markRenderDeleted(id: String) throws {
    try db.run("UPDATE renders SET deleted_at=? WHERE id=? AND deleted_at IS NULL", [now, id])
  }

  /// Atomically claims a render for rendering. False when another writer already has it in `rendering`.
  func claimRender(id: String) throws -> Bool {
    try db.run("UPDATE renders SET status='rendering', error=NULL WHERE id=? AND status<>'rendering' AND deleted_at IS NULL",
               [id]) == 1
  }

  /// Resets a `rendering` row whose owner process is gone (only call while holding its lock file).
  func resetStaleRender(id: String) throws {
    try db.run("UPDATE renders SET status='failed', error='interrupted' WHERE id=? AND status='rendering'", [id])
  }

  /// Records a finished render's results in one statement.
  func finishRender(id: String, outputPath: String, coverPath: String?, loudness: LoudnessInfo?, duration: Double,
                    size: Int64) throws {
    try db.run("""
      UPDATE renders SET status='done', error=NULL, output_path=?, cover_path=?, loudness=?, duration=?, size=? WHERE id=?
      """, [outputPath, coverPath, loudness.map { JSONCoding.string($0) }, duration, size, id])
  }

  /// Records a finished photo render in one statement: the first file, the rest and the total size together, so a row
  /// is never `done` with some of its files unlisted.
  func finishPhotoRender(id: String, paths: [String], size: Int64) throws {
    try db.run("""
      UPDATE renders SET status='done', error=NULL, output_path=?, more_paths=?, cover_path=NULL, loudness=NULL, duration=0, size=?
        WHERE id=?
      """, [paths.first, JSONCoding.pathList(Array(paths.dropFirst())), size, id])
  }

  /// Where every file of a render is now, in one statement (the engine calls this after moving files to Posted).
  /// `morePaths` nil leaves that column as it is (a video).
  public func setRenderFiles(id: String, outputPath: String?, coverPath: String?, morePaths: [String]?) throws {
    try db.run("UPDATE renders SET output_path=?, cover_path=?, more_paths=COALESCE(?, more_paths) WHERE id=?",
               [outputPath, coverPath, morePaths.map { JSONCoding.pathList($0) }, id])
  }

  /// The oldest live, unfinished row for a render key (all writers converge on it).
  func renderRow(videoId: String, versionNo: Int, hash: String, scope: String) throws -> Render? {
    try db.one("""
      SELECT * FROM renders WHERE video_id=? AND version_no=? AND edit_hash=? AND scope=? AND deleted_at IS NULL
        AND status<>'done'
      ORDER BY created_at, id LIMIT 1
      """, [videoId, versionNo, hash, scope]).map(Store.render)
  }
}
