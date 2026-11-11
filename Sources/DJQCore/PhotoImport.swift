import CryptoKit
import Foundation

/// Photo posts (round 21, DECISIONS-R21.md D1–D3). A photo post is a `Video` with `photos`: short-form, `duration` 0,
/// in the one Photos session (`Session.photosId`, folder `Paths.photos`), never in a videos.json, needing no score.
///
/// DJ Queue keeps its own copy of every photo in `Photos/Originals/<post id>/NN-<photo id>.<ext>`; the file Eric picked
/// is only ever read. Renders go to `Photos/Ready to Post/Shortform/` and move to `Photos/Posted/Shortform/` like any
/// session's.
public final class PhotoImport: @unchecked Sendable {
  public enum Mode: String, Sendable, CaseIterable {
    /// One post from every file, in the order given (D3: the default).
    case carousel
    /// One post per file ("A post per photo").
    case separate
  }

  /// A file that wasn't taken, and why.
  public struct Skipped: Codable, Sendable, Hashable {
    public var file: String
    public var reason: String
    public init(file: String, reason: String) { self.file = file; self.reason = reason }
  }

  public struct Result: Sendable {
    /// The posts made, in order.
    public var posts: [Video]
    public var skipped: [Skipped]
  }

  /// What `append`, `remove` and `reorder` did.
  public struct Change: Sendable {
    /// The post afterwards.
    public var video: Video
    /// `append` only: the files it left out.
    public var skipped: [Skipped] = []
    /// The journal entry for `djq bulk undo` and the app's ⌘Z (nil: not journaled, or nothing changed).
    public var batchId: String?
  }

  let store: Store
  let fm = FileManager.default

  public init(store: Store) { self.store = store }

  // MARK: Import

  /// The Photos session row, made on first use. Its folder follows `Paths.photos`.
  @discardableResult
  public func ensureSession() throws -> Session {
    let folder = store.paths.photos.path
    if var s = try store.session(id: Session.photosId) {
      if s.folder != folder || s.missing {
        s.folder = folder
        s.missing = false
        try store.save(s)
      }
      return s
    }
    let s = Session(id: Session.photosId, folder: folder, name: "Photos", date: nil, discoveredAt: store.clock.now, missing: false)
    try store.save(s)
    return s
  }

  /// Makes photo posts from `files`: one carousel of them all, or a post per file. Each file is copied (never moved or
  /// changed); a file that can't be used is skipped with the reason. A new post lands in Edit with no score, no text,
  /// the centred crop and YouTube off. `title` is given to every post made. Nothing is sent to the Queue.
  @discardableResult
  public func add(files: [URL], mode: Mode = .carousel, title: String? = nil, titleSource: String = "app") throws -> Result {
    var skipped: [Skipped] = []
    var good = files.filter { url in
      if let why = Self.refusal(url) { skipped.append(Skipped(file: url.path, reason: why)); return false }
      return true
    }
    if mode == .carousel, good.count > PhotoRules.maxPerPost {
      for u in good[PhotoRules.maxPerPost...] { skipped.append(Skipped(file: u.path, reason: Self.fullReason)) }
      good = Array(good[..<PhotoRules.maxPerPost])
    }
    let groups = mode == .carousel ? (good.isEmpty ? [] : [good]) : good.map { [$0] }
    var posts: [Video] = []
    for group in groups {
      let id = newId()
      let (copied, bad) = try copy(group, postId: id, startingAt: 1)
      skipped += bad
      guard let first = copied.first else {
        try? fm.removeItem(at: originals(id))
        continue
      }
      do {
        posts.append(try store.db.transaction {
          try insert(id: id, photos: copied.map(\.item), baseName: first.source.deletingPathExtension().lastPathComponent,
                     title: title, titleSource: titleSource)
        })
      } catch {
        try? fm.removeItem(at: originals(id))  // nothing in the database points at these copies
        throw error
      }
    }
    return Result(posts: posts, skipped: skipped)
  }

  /// Adds photos to the end of a post. One journal entry (`journal: false` inside an open editor entry, whose commit
  /// records it with the rest of the session).
  @discardableResult
  public func append(files: [URL], to videoId: String, journal: Bool = true) throws -> Change {
    let v = try post(videoId)
    var skipped: [Skipped] = []
    var good = files.filter { url in
      if let why = Self.refusal(url) { skipped.append(Skipped(file: url.path, reason: why)); return false }
      return true
    }
    let room = max(0, PhotoRules.maxPerPost - v.photoCount)
    if good.count > room {
      for u in good[room...] { skipped.append(Skipped(file: u.path, reason: Self.fullReason)) }
      good = Array(good[..<room])
    }
    let (copied, bad) = try copy(good, postId: v.id, startingAt: nextNumber(v))
    let items = copied.map(\.item)
    skipped += bad
    guard !items.isEmpty else { return Change(video: v, skipped: skipped, batchId: nil) }
    var out = try change("photo-add", v.id, journal: journal) { cur in cur + items }
    out.skipped = skipped
    try store.logEvent("photo", "Added \(items.count) photo\(items.count == 1 ? "" : "s") to \(v.name)", videoId: v.id)
    return out
  }

  /// Takes one photo out of a post. The last photo can't go: a post needs one. Its copy stays in Originals, so undo
  /// brings it back.
  @discardableResult
  public func remove(photoId: String, from videoId: String, journal: Bool = true) throws -> Change {
    let v = try post(videoId)
    guard (v.photos ?? []).contains(where: { $0.id == photoId }) else { throw EngineError("\(v.name) has no photo \(photoId)") }
    guard v.photoCount > 1 else { throw EngineError("A post needs at least one photo, so the last one stays") }
    let index = (v.photos ?? []).firstIndex { $0.id == photoId } ?? 0
    let count = v.photoCount
    // A journaled removal (djq, a list) also keeps each text with its photos (`PhotoTextRanges`), in the same entry. An
    // open editor passes `journal: false` and applies the same rule to the versions it holds.
    let out = try change("photo-remove", v.id, journal: journal, also: journal ? {
      for ver in try self.store.versions(videoId: v.id) {
        let r = PhotoTextRanges.removing(index: index, from: ver, count: count)
        if r.version != ver { try self.store.save(r.version, videoId: v.id) }
      }
    } : nil) { cur in cur.filter { $0.id != photoId } }
    try store.logEvent("photo", "Removed a photo from \(v.name)", videoId: v.id)
    return out
  }

  /// Makes a post's photo list `photos` again: the undo and redo of a list change in an open editor, with the same
  /// photo ids and files (a removed photo's copy stays in Originals), so nothing is copied and each crop still belongs
  /// to its photo. Every file must be on disk and the list can't be empty. No journal: the editor's own entry covers it.
  @discardableResult
  public func setPhotos(_ photos: [PhotoItem], videoId: String) throws -> Video {
    let v = try post(videoId)
    guard !photos.isEmpty else { throw EngineError("A post needs at least one photo") }
    var probe = v
    probe.photos = photos
    for p in photos where !fm.fileExists(atPath: try store.photoURL(p, of: probe).path) {
      throw EngineError("\(URL(fileURLWithPath: p.file).lastPathComponent) isn't on disk any more")
    }
    try store.db.transaction {
      try store.writePhotos(photos, videoId: videoId)
      try store.refreshState(videoId: videoId)
    }
    return try post(videoId)
  }

  /// Puts a post's photos in the order of `ids` (every photo id, once). The first photo is the cover (D15).
  @discardableResult
  public func reorder(videoId: String, ids: [String], journal: Bool = true) throws -> Change {
    let v = try post(videoId)
    let cur = v.photos ?? []
    guard Set(ids) == Set(cur.map(\.id)), ids.count == cur.count else {
      throw EngineError("Reorder needs every photo of \(v.name) once")
    }
    guard ids != cur.map(\.id) else { return Change(video: v, batchId: nil) }
    let byId = Dictionary(cur.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return try change("photo-reorder", v.id, journal: journal) { _ in ids.compactMap { byId[$0] } }
  }

  /// One photo-list change: the new list, the edit without crops of photos that left, the state, and (when asked) one
  /// journal entry, the way every other single-clip action gets its undo (`BulkActions.record`).
  private func change(_ action: String, _ videoId: String, journal: Bool, also: (() throws -> Void)? = nil,
                      _ next: ([PhotoItem]) -> [PhotoItem]) throws -> Change {
    var batch: String?
    func apply() throws {
      let cur = try post(videoId).photos ?? []
      let new = next(cur)
      try store.writePhotos(new, videoId: videoId)
      var e = try store.edit(videoId: videoId)
      let keep = Set(new.map(\.id))
      let stale = e.photoCrops.keys.filter { !keep.contains($0) }
      if !stale.isEmpty {
        for k in stale { e.photoCrops.removeValue(forKey: k) }
        try store.save(e, videoId: videoId, remembersCrop: false)
      }
      try also?()
      try store.refreshState(videoId: videoId)
    }
    if journal {
      batch = try BulkActions(store: store).record(action, ids: [videoId]) { try apply() }.batchId
    } else {
      try store.db.transaction { try apply() }
    }
    return Change(video: try post(videoId), batchId: batch)
  }

  // MARK: Files

  /// Intake's photo check: a post with a photo file gone is `missing`, like a clip whose file is gone, and comes back
  /// when the file does. Returns the names of posts that just went missing. The Photos session itself is never missing.
  @discardableResult
  public func checkFiles() throws -> [String] {
    var gone: [String] = []
    // The Photos session follows `Paths.photos` (a moved or copied root), and is never missing.
    if try store.session(id: Session.photosId) != nil { try ensureSession() }
    for v in try store.videos(where: "photos IS NOT NULL") {
      // A file that is there but can't be read as a picture (cut short, overwritten) can't post either: it counts as gone,
      // so the post waits in Edit with "File missing" instead of failing at render time.
      let missing = try (v.photos ?? []).contains { p in
        let url = try store.photoURL(p, of: v)
        return !fm.fileExists(atPath: url.path) || PhotoRenderer.pixelSize(of: url) == nil
      }
      guard missing != v.missing else { continue }
      try store.db.run("UPDATE videos SET missing=?, updated_at=? WHERE id=?", [missing, store.clock.now, v.id])
      try store.refreshState(videoId: v.id)
      if missing {
        gone.append(v.name)
        try store.logEvent("missing", "Photo file missing: \(v.name)", videoId: v.id)
      } else {
        try store.logEvent("relink", "Photo file is back: \(v.name)", videoId: v.id)
      }
    }
    return gone
  }

  /// The files of `v` that aren't on disk (relative to the Photos folder).
  public func missingFiles(_ v: Video) throws -> [String] {
    try (v.photos ?? []).filter { p in
      let url = try store.photoURL(p, of: v)
      return !fm.fileExists(atPath: url.path) || PhotoRenderer.pixelSize(of: url) == nil
    }.map(\.file)
  }

  /// Why a file can't be a photo (nil = it can): gone, a folder, a format DJ Queue doesn't take, or unreadable.
  public static func refusal(_ url: URL) -> String? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return "the file isn't there" }
    if isDir.boolValue { return "it's a folder" }
    guard PhotoRules.extensions.contains(url.pathExtension.lowercased()) else {
      return "not a photo format DJ Queue takes (JPEG, PNG, HEIC, WebP or TIFF)"
    }
    guard PhotoRenderer.pixelSize(of: url) != nil else { return "it can't be read as a photo" }
    return nil
  }

  static let fullReason = "a post holds at most \(PhotoRules.maxPerPost) photos"

  /// Size and SHA-256 of a photo file.
  public static func fingerprint(_ url: URL) -> String? {
    guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return "\(d.count)-" + SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
  }

  func originals(_ postId: String) -> URL { store.paths.photos.appendingPathComponent("Originals/\(postId)") }

  /// Copies `files` into the post's Originals folder as `NN-<photo id>.<ext>`. A copy that fails is skipped with the reason.
  private func copy(_ files: [URL], postId: String, startingAt first: Int) throws -> ([(item: PhotoItem, source: URL)], [Skipped]) {
    guard !files.isEmpty else { return ([], []) }
    try ensureSession()
    let dir = originals(postId)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var items: [(item: PhotoItem, source: URL)] = [], skipped: [Skipped] = []
    var n = first
    var taken = Set((try store.video(id: postId)?.photos ?? []).map(\.id))
    for src in files {
      var pid = PhotoItem.newId()
      while !taken.insert(pid).inserted { pid = PhotoItem.newId() }  // ids are the keys of `Edit.photoCrops`
      let name = String(format: "%02d-%@.%@", n, pid, src.pathExtension.lowercased())
      let dest = dir.appendingPathComponent(name)
      do {
        // The file itself, never a link to it: an alias or symlink Eric picked still gives DJ Queue its own copy (D2).
        try fm.copyItem(at: src.resolvingSymlinksInPath(), to: dest)
        guard let size = PhotoRenderer.pixelSize(of: dest) else {
          try? fm.removeItem(at: dest)
          skipped.append(Skipped(file: src.path, reason: "it can't be read as a photo"))
          continue
        }
        items.append((PhotoItem(id: pid, file: "Originals/\(postId)/\(name)", width: size.width, height: size.height,
                                fingerprint: Self.fingerprint(dest)), src))
        n += 1
      } catch {
        skipped.append(Skipped(file: src.path, reason: "couldn't copy it: \(error.localizedDescription)"))
      }
    }
    return (items, skipped)
  }

  /// The next NN for a post's file names: one past the highest in use, so names never repeat after a remove.
  private func nextNumber(_ v: Video) -> Int {
    let used = (v.photos ?? []).compactMap { Int(URL(fileURLWithPath: $0.file).lastPathComponent.prefix(2)) }
    let onDisk = ((try? fm.contentsOfDirectory(atPath: originals(v.id).path)) ?? []).compactMap { Int($0.prefix(2)) }
    return ((used + onDisk).max() ?? 0) + 1
  }

  private func post(_ id: String) throws -> Video {
    guard let v = try store.video(id: id) else { throw EngineError("No post \(id)") }
    guard v.isPhoto else { throw EngineError("\(v.name) is a video, not a photo post") }
    return v
  }

  /// A name no other photo post has ("IMG_1234", then "IMG_1234 2"): renders are named after it. Names are compared
  /// the way a file name would be: "Flyer" and "flyer" are one name on a Mac, and so are "a:b" and "a-b" once written.
  private func freeName(_ base: String) throws -> String {
    let taken = Set(try store.videos(where: "photos IS NOT NULL").map { Self.fileNameKey($0.name) })
    guard taken.contains(Self.fileNameKey(base)) else { return base }
    var n = 2
    while taken.contains(Self.fileNameKey("\(base) \(n)")) { n += 1 }
    return "\(base) \(n)"
  }

  /// What a post's name comes to as part of a render's file name on a case-insensitive volume: `Renderer.outputName`'s
  /// replacements, one Unicode form, no case.
  static func fileNameKey(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
  }

  private func insert(id: String, photos: [PhotoItem], baseName base: String, title: String?, titleSource: String) throws -> Video {
    let now = store.clock.now
    let settings = try store.settings()
    let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    var v = Video(id: id, sessionId: Session.photosId, name: try freeName(base), tags: [base], type: .short, contentType: "photo",
                  kind: settings.defaults.kind, file: photos[0].file, fingerprint: nil, fileSize: nil, duration: 0,
                  markedStart: nil, markedEnd: nil, start: nil, end: nil, grace: nil, audio: nil, part: nil, score: nil,
                  state: .needsEdit, excluded: false, missing: false, inManifest: false, notes: "", alreadyPostedOn: [],
                  longformURL: nil, createdAt: now, updatedAt: now)
    if let t, !t.isEmpty {
      v.title = t
      v.titleSource = titleSource
    }
    v.photos = photos
    try store.save(v)
    try store.writePhotos(photos, videoId: id)  // file, fingerprint, size and picture size from the photos
    var e = Edit()
    Store.keepPhotoPlatforms(&e)
    try store.save(e, videoId: id, remembersCrop: false)  // stored with YouTube off (D8); also derives the state
    try store.logEvent("photo", "New photo post \(v.name) (\(photos.count) photo\(photos.count == 1 ? "" : "s"))", videoId: id)
    guard let saved = try store.video(id: id) else { throw StoreError.corruptRow("videos", id) }
    return saved
  }
}

extension Store {
  /// Where a photo's file is: under this store's Photos folder (`Paths.photos`), whatever folder the session row
  /// names, so a database copied from another root never reads or writes that root's photos.
  public func photoURL(_ photo: PhotoItem, of v: Video) throws -> URL {
    paths.photos.appendingPathComponent(photo.file)
  }

  /// Every photo file of a post, in order.
  public func photoURLs(_ v: Video) throws -> [URL] { try (v.photos ?? []).map { try photoURL($0, of: v) } }

  /// Writes a photo post's photos and everything on its row that follows from them: `file` (the first photo), the
  /// fingerprint and size of the set, and the first photo's picture size. Nothing else on the row changes.
  func writePhotos(_ photos: [PhotoItem], videoId: String) throws {
    guard let v = try video(id: videoId) else { throw StoreError.corruptRow("videos", videoId) }
    var after = v
    after.photos = photos
    let sizes = try photos.map { Intake.size(try photoURL($0, of: after)) }.filter { $0 >= 0 }
    let print = photos.map { $0.fingerprint ?? $0.file }.joined(separator: "|")
    let fp = photos.isEmpty ? nil : SHA256.hash(data: Data(print.utf8)).map { String(format: "%02x", $0) }.joined()
    try db.run("""
      UPDATE videos SET photos=?, file=?, fingerprint=?, file_size=?, source_width=?, source_height=?, updated_at=? WHERE id=?
      """, [JSONCoding.string(photos), photos.first?.file ?? v.file, fp, sizes.isEmpty ? nil : sizes.reduce(0, +),
            photos.first?.width, photos.first?.height, now, videoId])
  }
}
