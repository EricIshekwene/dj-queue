import AppKit
import DJQCore
import Foundation
import UniformTypeIdentifiers

/// Round 21: the photo half of the editor (DECISIONS-R21.md D5, D7, D15, D20). A photo post opens in the same editor as
/// a clip. What differs is here: which photo is on the canvas, each photo's crop, adding, removing and reordering
/// photos, and a text's range of photos in place of a time window.
///
/// The playhead is the photo: `playback.time` is the current photo's index (photo i is the interval [i, i + 1), Core's
/// unit), and `playback.still` is that photo, decoded off the main thread.
extension EditorModel {
  // MARK: Which photo

  var isPhoto: Bool { video?.isPhoto == true }
  var photos: [PhotoItem] { video?.photos ?? [] }
  var photoCount: Int { photos.count }
  var isCarousel: Bool { photoCount > 1 }

  /// The photo on the canvas (0-based), kept inside the post.
  var photoIndex: Int { min(max(0, Int(playback.time.rounded(.down))), max(0, photoCount - 1)) }
  var currentPhoto: PhotoItem? { photos.indices.contains(photoIndex) ? photos[photoIndex] : nil }

  /// Shows photo `i` on the canvas. Its picture comes from the cache or is read off the main thread.
  func selectPhoto(_ i: Int) {
    let list = photos
    guard !list.isEmpty else { playback.showPhoto(nil, index: 0); return }
    let index = min(max(0, i), list.count - 1), photo = list[index]
    objectWillChange.send()  // the inspector reads the current photo's crop, and only the playhead object says it moved
    setSourceSize(CGSize(width: photo.width, height: photo.height))
    guard let v = video, let url = try? store.photoURL(photo, of: v) else { playback.showPhoto(nil, index: index); return }
    let key = EditorPhotoImages.key(photo, url: url)
    if let img = EditorPhotoImages.canvas.value(key) {
      playback.showPhoto(img, index: index)
    } else if snapshotMode {
      playback.showPhoto(EditorPhotoImages.decode(url, key: key, maxPixel: EditorPhotoImages.canvasPixels, into: EditorPhotoImages.canvas), index: index)
    } else {
      playback.showPhoto(nil, index: index)
      let id = videoId
      Task.detached(priority: .userInitiated) { [weak self] in
        let img = EditorPhotoImages.decode(url, key: key, maxPixel: EditorPhotoImages.canvasPixels, into: EditorPhotoImages.canvas)
        await self?.photoDecoded(img, photoId: photo.id, videoId: id)
      }
    }
    refreshPhotoImages()
    preloadNeighbours(of: index)
  }

  private func photoDecoded(_ image: CGImage?, photoId: String, videoId id: String) {
    guard videoId == id, let p = currentPhoto, p.id == photoId else { return }
    playback.showPhoto(image, index: photoIndex)
    refreshPhotoImages()
  }

  /// The photos either side of `index`, read ahead so ← / → shows them at once.
  private func preloadNeighbours(of index: Int) {
    guard !snapshotMode, let v = video else { return }
    let near = [index + 1, index - 1].filter { photos.indices.contains($0) }.compactMap { i -> (URL, String)? in
      guard let url = try? store.photoURL(photos[i], of: v) else { return nil }
      return (url, EditorPhotoImages.key(photos[i], url: url))
    }
    guard !near.isEmpty else { return }
    Task.detached(priority: .utility) {
      for (url, key) in near where EditorPhotoImages.canvas.value(key) == nil {
        _ = EditorPhotoImages.decode(url, key: key, maxPixel: EditorPhotoImages.canvasPixels, into: EditorPhotoImages.canvas)
      }
    }
  }

  /// The photo on the canvas is one whose file is gone.
  var currentPhotoMissing: Bool { currentPhoto.map { missingPhotos.contains($0.id) } ?? false }

  /// Where the current photo's file should be (the missing state names it).
  var currentPhotoURL: URL? {
    guard let v = video, let p = currentPhoto else { return fileURL }
    return (try? store.photoURL(p, of: v)) ?? fileURL
  }

  /// ← / →: the photo before or after. Nothing past either end.
  func stepPhoto(_ d: Int) {
    let i = photoIndex + d
    guard photos.indices.contains(i) else { return }
    selectPhoto(i)
  }

  // MARK: Pictures

  /// What the composed canvas picture is made from. It changes with the photo, its crop and the shape.
  var photoCanvasKey: String? {
    guard let p = currentPhoto else { return nil }
    return EditorPhotoImages.composeKey(p, crop: PhotoRules.crop(for: p, edit: edit, aspect: aspect), aspect: aspect)
  }

  /// Brings the strip's thumbnails and the canvas picture up to date with the photos, their crops and the shape.
  func refreshPhotoImages() {
    guard let v = video, v.isPhoto else { return }
    let a = aspect, e = edit
    let jobs = photos.compactMap { p -> EditorPhotoImages.Job? in
      guard let url = try? store.photoURL(p, of: v) else { return nil }
      return EditorPhotoImages.Job(photo: p, url: url, crop: PhotoRules.crop(for: p, edit: e, aspect: a), aspect: a)
    }
    photoImages.refreshThumbs(jobs, sync: snapshotMode)
    if let p = currentPhoto, let still = playback.still, let job = jobs.first(where: { $0.photo.id == p.id }) {
      photoImages.compose(job, from: still, sync: snapshotMode)
    }
  }

  // MARK: Crop per photo (D5)

  /// The current photo's own crop, kept inside the photo in the post's shape. One that can't be rendered isn't written.
  func setPhotoCrop(_ c: CropRect) {
    guard let p = currentPhoto else { return }
    let size = CGSize(width: p.width, height: p.height)
    let fitted = EditorGeometry.clamp(c, source: size)
    guard Media.cropProblem(fitted, aspect: aspect, sourceWidth: p.width, sourceHeight: p.height) == nil else { return }
    updateEdit { $0.photoCrops[p.id] = fitted }
  }

  /// Back to the centred crop for the current photo.
  func resetPhotoCrop() {
    guard let p = currentPhoto else { return }
    updateEdit { $0.photoCrops[p.id] = nil }
  }

  /// The current photo's zoom and place, as fractions of the picture, on every other photo. Photos of another size or
  /// shape get the nearest framing that fits inside them. One undo step.
  func useFramingForEveryPhoto() {
    guard let cur = currentPhoto, photoCount > 1 else { return }
    let a = aspect, c = crop, z = zoom
    let fx = (c.x + c.w / 2) / Double(max(cur.width, 1)), fy = (c.y + c.h / 2) / Double(max(cur.height, 1))
    lastUndoBreak()
    updateEdit { e in
      e.photoCrops[cur.id] = c
      for p in photos where p.id != cur.id {
        let size = CGSize(width: p.width, height: p.height)
        let m = EditorGeometry.maxCropSize(source: size, aspect: a)
        let w = m.width / z, h = m.height / z
        let fitted = EditorGeometry.clamp(CropRect(x: fx * size.width - w / 2, y: fy * size.height - h / 2, w: w, h: h), source: size)
        if Media.cropProblem(fitted, aspect: a, sourceWidth: p.width, sourceHeight: p.height) == nil { e.photoCrops[p.id] = fitted }
      }
    }
    lastUndoBreak()
    show("Every photo has this framing · ⌘Z takes it back")
  }

  /// What a tile's mark says about a photo's shape (nil = nothing to say): much of it is cut off by a crop Eric hasn't
  /// set himself, or the crop has fewer pixels than the 1080-wide output.
  func photoNotice(_ p: PhotoItem) -> String? {
    let a = aspect
    let c = PhotoRules.crop(for: p, edit: edit, aspect: a)
    if EditorGeometry.upscale(c, aspect: a) > 1.01 {
      return "This photo is \(Int(c.w)) px wide in the frame, under the 1080 it posts at, so it may look soft"
    }
    guard !PhotoRules.hasOwnCrop(p, edit: edit, aspect: a) else { return nil }
    let kept = (c.w * c.h) / Double(max(1, p.width * p.height))
    guard kept < 0.7 else { return nil }
    let wide = Double(p.width) / Double(max(1, p.height)) > a.ratio
    return "\(a.rawValue) cuts off the \(wide ? "sides" : "top and bottom") of this photo. Check its crop in the Frame view."
  }

  // MARK: Adding, removing and reordering (D15)

  /// Why photos can't be added, removed or moved right now (nil = they can).
  var photosOffReason: String? {
    if readOnly { return EditorView.readOnlyReason }
    if video == nil { return "The post is still loading" }
    return photoBusy ? "Photos are being added" : nil
  }

  var addPhotosOffReason: String? {
    photosOffReason ?? (photoCount >= PhotoRules.maxPerPost ? "A post holds at most \(PhotoRules.maxPerPost) photos" : nil)
  }

  var removePhotoOffReason: String? {
    photosOffReason ?? (photoCount <= 1 ? "A post needs at least one photo, so the last one stays" : nil)
  }

  /// The Add tile: the file picker for photos. A check can't open a real panel, so it calls `addPhotos` itself.
  func pickPhotos() {
    guard addPhotosOffReason == nil, !AppModel.isSnapshotRun else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = PhotoRules.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    panel.message = "Add photos to this post"
    panel.prompt = "Add"
    panel.begin { [weak self] response in
      guard response == .OK else { return }
      let files = panel.urls
      MainActor.assumeIsolated { self?.addPhotos(files) }
    }
  }

  /// Adds photos to the end of the post (picked or dropped). The files are copied off the main thread; the change is
  /// part of the open editor session (`journal: false`) and one step of the editor's own undo.
  func addPhotos(_ files: [URL]) {
    guard addPhotosOffReason == nil, !files.isEmpty, let v = video, v.isPhoto else {
      if let why = addPhotosOffReason, !files.isEmpty { show(why) }
      return
    }
    commitCaptionDraft()
    flush()  // pending edits land first, on the same queue as the copy
    photoBusy = true
    let store = store, id = videoId
    Self.saveQueue.async { [weak self] in
      let result = Result { try PhotoImport(store: store).append(files: files, to: id, journal: false) }
      DispatchQueue.main.async {
        guard let self, self.videoId == id else { return }
        self.photoBusy = false
        switch result {
        case .failure(let error): self.show("Couldn't add the photos: \(error.localizedDescription)")
        case .success(let change):
          let added = change.video.photoCount - self.photoCount
          if added > 0 {
            self.markUndo(coalesce: false)
            self.photosChanged(change.video, select: self.photoCount)
          }
          self.show(Self.addedMessage(added, skipped: change.skipped))
        }
      }
    }
  }

  private static func addedMessage(_ added: Int, skipped: [PhotoImport.Skipped]) -> String {
    let done = added == 0 ? "No photo added" : "\(added) photo\(added == 1 ? "" : "s") added"
    guard let first = skipped.first else { return done }
    let name = URL(fileURLWithPath: first.file).lastPathComponent
    return skipped.count == 1 ? "\(done) · \(name) was left out: \(first.reason)"
                              : "\(done) · \(skipped.count) files were left out: \(first.reason)"
  }

  /// Takes one photo out of the post. Its copy stays on disk, so ⌘Z brings it back.
  func removePhoto(_ photoId: String) {
    guard removePhotoOffReason == nil, let at = photos.firstIndex(where: { $0.id == photoId }) else { return }
    let was = photoIndex
    guard let fresh = photoChange({ try $0.remove(photoId: photoId, from: $1, journal: false) }) else { return }
    photosChanged(fresh, select: at < was ? was - 1 : was)
    show("Photo removed · ⌘Z brings it back")
  }

  /// Puts photo `photoId` at place `index` (0-based). The first photo is the cover.
  func movePhoto(_ photoId: String, to index: Int) {
    var ids = photos.map(\.id)
    guard photosOffReason == nil, let from = ids.firstIndex(of: photoId) else { return }
    let to = min(max(0, index), ids.count - 1)
    guard to != from else { return }
    ids.remove(at: from)
    ids.insert(photoId, at: to)
    let order = ids
    guard let fresh = photoChange({ try $0.reorder(videoId: $1, ids: order, journal: false) }) else { return }
    photosChanged(fresh, select: to)
    if to == 0 { show("This photo is now the cover") } else if from == 0 { show("The cover is now the photo in first place") }
  }

  /// One photo-list change in the store, after pending saves, as its own undo step. nil = it failed (and said why).
  private func photoChange(_ change: @escaping @Sendable (PhotoImport, String) throws -> PhotoImport.Change) -> Video? {
    commitCaptionDraft()
    flush()
    let store = store, id = videoId
    do {
      let fresh = try Self.saveQueue.sync { try change(PhotoImport(store: store), id).video }
      markUndo(coalesce: false)
      return fresh
    } catch {
      show("Couldn't change the photos: \(error.localizedDescription)")
      return nil
    }
  }

  /// The editor after the store's photo list changed: the post, the photo on the canvas, pictures, texts and issues.
  private func photosChanged(_ fresh: Video, select index: Int) {
    adoptPhotos(from: fresh)
    selectPhoto(index)
    refreshOverlay()
    revalidate()
    if !snapshotMode { ChangeSignal.post() }
  }

  /// Undo and redo: makes the stored photo list `target` again. A photo that comes back is added from DJ Queue's own
  /// copy (a removed photo's file stays in Originals), which gives it a new id; the pairs returned are those renames,
  /// already applied to the editor's history.
  func restorePhotos(_ target: [PhotoItem]) -> [(old: PhotoItem, new: PhotoItem)] {
    guard let v = video, v.isPhoto, !target.isEmpty else { return [] }
    let store = store, id = videoId
    var renamed: [(old: PhotoItem, new: PhotoItem)] = []
    do {
      let (fresh, pairs) = try Self.saveQueue.sync { () throws -> (Video, [(PhotoItem, PhotoItem)]) in
        let importer = PhotoImport(store: store)
        guard var now = try store.video(id: id) else { throw EngineError("No post \(id)") }
        var pairs: [(PhotoItem, PhotoItem)] = []
        for p in target where !(now.photos ?? []).contains(where: { $0.id == p.id }) {
          let before = Set((now.photos ?? []).map(\.id))
          now = try importer.append(files: [try store.photoURL(p, of: now)], to: id, journal: false).video
          if let new = (now.photos ?? []).first(where: { !before.contains($0.id) }) { pairs.append((p, new)) }
        }
        let ids = target.compactMap { p in pairs.first { $0.0.id == p.id }?.1.id ?? ((now.photos ?? []).contains { $0.id == p.id } ? p.id : nil) }
        for p in now.photos ?? [] where !ids.contains(p.id) { now = try importer.remove(photoId: p.id, from: id, journal: false).video }
        if Set(ids) == Set((now.photos ?? []).map(\.id)) { now = try importer.reorder(videoId: id, ids: ids, journal: false).video }
        return (now, pairs)
      }
      for (old, new) in pairs {
        renameInHistory(old, to: new)
        renamed.append((old, new))
      }
      let was = currentPhoto?.id
      adoptPhotos(from: fresh)
      selectPhoto(photos.firstIndex { $0.id == was } ?? photoIndex)
      revalidate()
      if !snapshotMode { ChangeSignal.post() }
    } catch {
      show("Couldn't put the photos back: \(error.localizedDescription)")
    }
    return renamed
  }

  // MARK: Text on a range of photos (D7)

  /// A photo post that has no text at all yet: nothing typed, nothing chosen, no extra texts (the state it starts in).
  var photoHasNoTextYet: Bool {
    guard isPhoto else { return false }
    let r = resolved
    return r.isDefault("text") && r.isDefault("noText") && r.moreText.isEmpty && !ownsField(["text"])
  }

  /// The photos text `id` shows on (1-based, inclusive). nil = none: its window is past the last photo.
  func textRange(_ id: String) -> ClosedRange<Int>? {
    guard let l = texts.first(where: { $0.id == id }), let w = Self.photoWindow(l, count: photoCount) else { return nil }
    return PhotoRules.photoRange(w, count: photoCount)
  }

  /// A text's window on a post of `count` photos by the renderer's rule (`PreviewKeys.layerWindows`), also for a text
  /// that isn't drawn yet: an empty one still has a place on the timeline. nil = it shows on no photo.
  private static func photoWindow(_ l: TextLayer, count: Int) -> ClosedRange<Double>? {
    let d = Double(count)
    guard d > 0 else { return nil }
    let s = max(0, l.start ?? 0), e = min(d + 1, l.end ?? (d + 1))
    if l.id == TextLayer.firstId { return e <= s || s >= d ? 0...(d + 1) : s...e }
    return s >= d || e <= s ? nil : s...e
  }

  /// "Every photo" · "Photo 2" · "Photos 2–4".
  func textRangeLabel(_ id: String) -> String { PhotoRules.rangeLabel(textRange(id), count: photoCount) }

  /// Sets the photos text `id` shows on. nil, or a range that covers the whole post, is "every photo": no window is
  /// stored, so photos added later get the text too. `step`: its own undo step (a button), not part of a drag.
  func setTextRange(_ id: String, _ range: ClosedRange<Int>?, step: Bool = false) {
    let n = photoCount
    if step { lastUndoBreak() }
    defer { if step { lastUndoBreak() } }
    if let r = range, !(r.lowerBound <= 1 && r.upperBound >= n) {
      let w = PhotoRules.window(fromPhoto: min(max(1, r.lowerBound), n), toPhoto: min(max(r.lowerBound, r.upperBound), n))
      setTextWindow(id, start: w.start, end: w.end)
    } else if id == TextLayer.firstId {
      updateVersion { $0.textStart = nil; $0.textEnd = nil }
    } else {
      updateText(id) { $0.start = nil; $0.end = nil }
    }
  }

  /// Add text on a photo post: on the current photo of a carousel, on the photo of a single one (no window). The first
  /// text of a post with none is the version's own text; later ones are added like a clip's.
  func addPhotoText() {
    guard !readOnly, video != nil else { return }
    let i = photoIndex
    let window: (start: Double?, end: Double?) = isCarousel ? { let w = PhotoRules.window(fromPhoto: i + 1, toPhoto: i + 1); return (w.start, w.end) }()
                                                            : (nil, nil)
    let r = resolved
    if photoHasNoTextYet || (!r.noText && !r.hasText && r.moreText.isEmpty) {
      updateVersion(coalesce: false) { v in
        v.noText = false
        v.text = ""
        v.textStart = window.start
        v.textEnd = window.end
      }
      selectText(TextLayer.firstId)
      // The field isn't on screen until this change is drawn (the section showed "No text" a moment ago).
      DispatchQueue.main.async { [weak self] in self?.focusTextField += 1 }
      return
    }
    guard addTextOffReason == nil else { return }
    let like = selectedLayer
    let here = (i + 1)...(i + 1)
    let overlaps = textRange(like.id).map { $0.overlaps(here) } ?? false
    add(TextLayers.new(text: "", like: like, start: window.start, end: window.end), overlapping: !isCarousel || overlaps)
  }

  /// The text track of a photo post: one bar per text over the photos it shows on. `span` is in photos (photo i is
  /// [i, i + 1)). With "No text" on, or no text yet, it's the one stand-in bar.
  var photoTextBars: (bars: [EditorTimelineBar], laneCount: Int) {
    let r = resolved, n = photoCount, d = Double(max(1, n))
    func span(_ id: String) -> TextTimeline.Span {
      guard let range = textRange(id) else { return (max(0, d - 1), d) }
      return (Double(range.lowerBound - 1), Double(range.upperBound))
    }
    let shows = !r.noText && (r.hasText || !photoHasNoTextYet)
    let first = EditorTimelineBar(id: TextLayer.firstId, number: 1,
                                  label: r.hasText ? Captions.oneLine(r.text) : r.noText || photoHasNoTextYet ? "No text" : "Empty text",
                                  on: r.hasText && !r.noText, draggable: shows && n > 1, span: shows ? span(TextLayer.firstId) : (0, d), lane: 0)
    guard !r.noText else { return ([first], 1) }
    var bars = [first] + r.moreText.enumerated().map { i, l in
      EditorTimelineBar(id: l.id, number: i + 2, label: l.isBlank ? "Empty text" : Captions.oneLine(l.text), on: !l.isBlank, draggable: n > 1,
                        span: span(l.id), lane: 0)
    }
    let lanes = TextTimeline.lanes(bars.map(\.span))
    for i in bars.indices { bars[i].lane = lanes[i] }
    return (bars, (lanes.max() ?? 0) + 1)
  }
}
