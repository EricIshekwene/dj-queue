import AppKit
import DJQCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// Round 21, photo import (DECISIONS-R21.md D2, D3). The file picker, a drop on Edit, the import sheet and the check
/// script all end in `importPhotos`. Importing only ever adds posts to Edit: nothing here sends anything to the Queue.
struct PhotoImportRequest: Identifiable, Equatable {
  let id = UUID()
  /// The picked or dropped files, in order.
  var files: [URL]
}

/// The import's state outside `AppModel` (extensions can't hold it): the sheet's button reads `importing`, and the
/// last result stays for the toast's Open and for scripted runs.
@MainActor
@Observable
final class PhotoImportUI {
  static let shared = PhotoImportUI()
  /// An import is copying files now.
  var importing = false
  /// The posts the last import made, in order.
  var lastPosts: [String] = []
  /// The files the last import (or the last pick) left out, with the reason.
  var lastSkipped: [PhotoImport.Skipped] = []
  /// A file drag is over the Edit page.
  var dropTargeted = false
}

extension AppModel {
  // MARK: Picking

  /// "Add photos": the system file picker, several at once. One photo imports straight away; several open the sheet.
  /// A real panel lands on a display, so a snapshot or scripted run never opens it (they call `takePhotos`).
  func askAddPhotos() {
    guard !Self.isSnapshotRun else { return }
    let panel = NSOpenPanel()
    panel.title = "Add photos"
    panel.prompt = "Add"
    panel.message = "Pick one photo, or several for a carousel."
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = PhotoRules.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    panel.begin { [weak self] response in
      guard response == .OK else { return }
      let urls = panel.urls
      Task { @MainActor in self?.takePhotos(urls) }
    }
  }

  /// Opens the import sheet for these files.
  func askImportPhotos(_ files: [URL]) {
    guard !files.isEmpty else { return }
    photoImportRequest = PhotoImportRequest(files: files)
  }

  /// Picked or dropped files. The ones that can't be photos are refused in a toast, in `PhotoImport.refusal`'s words;
  /// of the rest, one imports straight away and several open the import sheet (or join the one that is open).
  func takePhotos(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    let known = Set(photoImportRequest?.files ?? [])
    let list = urls.filter { !known.contains($0) }
    Task.detached(priority: .userInitiated) {
      let refused = list.compactMap { u in PhotoImport.refusal(u).map { PhotoImport.Skipped(file: u.path, reason: $0) } }
      let bad = Set(refused.map(\.file))
      let good = list.filter { !bad.contains($0.path) }
      await MainActor.run { self.tookPhotos(good, refused: refused) }
    }
  }

  private func tookPhotos(_ good: [URL], refused: [PhotoImport.Skipped]) {
    PhotoImportUI.shared.lastSkipped = refused
    // One good photo goes straight in, and its "Added" toast carries the refusals; otherwise they get their own.
    let straightIn = photoImportRequest == nil && good.count == 1
    if !refused.isEmpty, !straightIn {
      show(DSToastModel(message: refused.count == 1 ? "1 file can't be added" : "\(refused.count) files can't be added",
                        detail: Self.skippedText(refused), tone: .danger, duration: 8))
    }
    guard !good.isEmpty else { return }
    if photoImportRequest != nil {
      photoImportRequest?.files += good  // the same request, so the sheet keeps what was typed
    } else if good.count == 1 {
      importPhotos(urls: good, mode: .carousel, title: nil, refused: refused)
    } else {
      askImportPhotos(good)
    }
  }

  // MARK: Importing

  /// THE import: copies the files into DJ Queue's own Photos folder off the main thread (`PhotoImport.add`) and makes
  /// one carousel or a post per file, in Edit. Then it signals, reloads and says what was added, with Open for the
  /// editor and every skipped file with its reason. The originals are only read. Nothing goes to the Queue.
  /// `refused`: files already turned away before this call, listed with the ones the import skips.
  func importPhotos(urls: [URL], mode: PhotoImport.Mode, title: String?, refused: [PhotoImport.Skipped] = []) {
    let ui = PhotoImportUI.shared
    guard !urls.isEmpty, !ui.importing else { return }
    ui.importing = true
    let s = store
    let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let given = name?.isEmpty == false ? name : nil
    Task.detached(priority: .userInitiated) {
      let out = Result { () throws -> PhotoImport.Result in
        var r = try PhotoImport(store: s).add(files: urls, mode: mode, title: given, titleSource: "app")
        r.skipped = refused + r.skipped
        return r
      }
      await MainActor.run { self.importedPhotos(out) }
    }
  }

  private func importedPhotos(_ out: Result<PhotoImport.Result, Error>) {
    let ui = PhotoImportUI.shared
    ui.importing = false
    photoImportRequest = nil
    switch out {
    case .failure(let e):
      ui.lastPosts = []
      refresh()
      show(e.localizedDescription, error: true)
    case .success(let r):
      ui.lastPosts = r.posts.map(\.id)
      ui.lastSkipped = r.skipped
      ChangeSignal.post()
      refresh()
      let skipped = r.skipped.isEmpty ? nil : Self.skippedText(r.skipped)
      guard let first = r.posts.first else {
        show(DSToastModel(message: "No photos added", detail: skipped, tone: .danger, duration: 8))
        return
      }
      let ids = r.posts.map(\.id)
      let detail = [r.posts.count == 1 && first.isCarousel ? "\(first.photoCount) photos" : nil, skipped].compactMap { $0 }
      show(DSToastModel(message: Self.importedText(r.posts), detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
                        tone: .success, actionTitle: "Open", action: { [weak self] in self?.openEditor(first.id, in: ids) },
                        duration: r.skipped.isEmpty ? 6 : 10))
    }
  }

  /// "Added 1 carousel to Edit" · "Added 1 photo to Edit" · "Added 5 posts to Edit".
  nonisolated static func importedText(_ posts: [Video]) -> String {
    if posts.count == 1, let p = posts.first { return "Added 1 \(p.isCarousel ? "carousel" : "photo") to Edit" }
    return "Added \(posts.count) posts to Edit"
  }

  /// One line per reason: "Skipped notes.txt: not a photo format DJ Queue takes (JPEG, PNG, HEIC, WebP or TIFF)".
  nonisolated static func skippedText(_ skipped: [PhotoImport.Skipped]) -> String {
    var order: [String] = [], files: [String: [String]] = [:]
    for s in skipped {
      if files[s.reason] == nil { order.append(s.reason) }
      files[s.reason, default: []].append(URL(fileURLWithPath: s.file).lastPathComponent)
    }
    return order.map { why in
      let names = files[why] ?? []
      let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
      return "Skipped \(shown): \(why)"
    }.joined(separator: "\n")
  }

  /// What the sheet's choice makes: "One carousel of 5 photos" · "5 posts, one photo each".
  nonisolated static func importPlan(count: Int, mode: PhotoImport.Mode) -> String {
    if count == 1 { return "One post with 1 photo" }
    switch mode {
    case .carousel:
      let n = min(count, PhotoRules.maxPerPost)
      return "One carousel of \(n) photos"
    case .separate: return "\(count) posts, one photo each"
    }
  }

  /// What Eric should know before adding: photos past the most a post holds, and each platform that gets fewer
  /// (`PhotoRules.notice`). Only a carousel has either.
  func importNotices(count: Int, mode: PhotoImport.Mode) -> [String] {
    guard mode == .carousel else { return [] }
    var out: [String] = []
    if count > PhotoRules.maxPerPost {
      out.append("A post holds at most \(PhotoRules.maxPerPost) photos, so the last \(count - PhotoRules.maxPerPost) are left out")
    }
    let n = min(count, PhotoRules.maxPerPost)
    out += settings.activePlatforms.compactMap { PhotoRules.notice(count: n, platform: $0) }
    return out
  }

  // MARK: Large previews

  /// Photo `index` of a photo post as it will post, at preview size, if loaded (no I/O). Single view and quick look
  /// step through these; cards use `poster(v)`, which is the first photo.
  func photoImage(_ v: Video, index: Int) -> NSImage? { posters[photoKey(v, index)] }

  /// Loads `photoImage` off the main thread once.
  func requestPhoto(_ v: Video, index: Int) {
    guard v.isPhoto, (0..<v.photoCount).contains(index) else { return }
    let k = photoKey(v, index)
    guard posters[k] == nil, !posterPending.contains(k) else { return }
    let s = store
    let load: @Sendable () -> NSImage? = {
      Media.thumbnail(store: s, video: v, maxHeight: Self.photoPreviewHeight, photo: index).flatMap { NSImage(contentsOf: $0) }
    }
    if frozen {
      if let img = load() { posters[k] = img }
      return
    }
    posterPending.insert(k)
    Task.detached(priority: .userInitiated) {
      let img = load()
      await MainActor.run {
        self.posterPending.remove(k)
        guard let img else { return }
        self.posters[k] = img
        self.dropFarPhotos(v, from: index)
      }
    }
  }

  /// A long carousel stepped end to end would keep every large photo decoded; only the ones near the photo on screen stay.
  private func dropFarPhotos(_ v: Video, from index: Int) {
    let prefix = "\(v.id)|photo"
    for k in posters.keys where k.hasPrefix(prefix) {
      guard let i = Int(k.dropFirst(prefix.count).prefix { $0 != "|" }), abs(i - index) > 3 else { continue }
      posters[k] = nil
    }
  }

  /// Tall enough for Single view and quick look on a Retina display.
  nonisolated static let photoPreviewHeight = 1280

  /// Starts with the post's id, so `previewChanged` frees it with the post's other covers.
  private func photoKey(_ v: Video, _ index: Int) -> String {
    "\(v.id)|photo\(index)|\(previewStamp(v.id))|g\(ThumbStamps.shared.gen(v.id))"
  }

  /// A photo post's pictures for a card: the mark, the shape and the per-photo images.
  func clipPhotos(_ v: Video, label: String) -> DSClipPhotos {
    let ratio = poster(v).flatMap { $0.size.height > 0 ? Double($0.size.width / $0.size.height) : nil } ?? settings.defaults.photoAspect.ratio
    return DSClipPhotos(count: v.photoCount, label: label, aspectRatio: ratio,
                        image: { [weak self] i in self?.photoImage(v, index: i) },
                        load: { [weak self] i in self?.requestPhoto(v, index: i) })
  }

  /// `ids` without the photo posts: a photo has nothing to play, so no proxy is ever asked for it.
  func playableIds(_ ids: [String]) -> [String] { ids.filter { videoById[$0]?.isPhoto != true } }

  // MARK: Files

  /// "Reveal in Finder" for a post: every file of it. A clip has one; a photo post has one per photo.
  func revealFiles(_ post: PlatformPost) {
    Task {
      guard let p = await prepare(post) else { return }
      NSWorkspace.shared.activateFileViewerSelecting(p.allFileURLs)
    }
  }

  /// "Copy file" for a post: every file of it on the pasteboard, to paste into Finder or an upload box.
  func copyFiles(_ post: PlatformPost) {
    Task {
      guard let p = await prepare(post) else { return }
      let files = p.allFileURLs
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects(files.map { $0 as NSURL })
      show(files.count == 1 ? "File copied" : "\(files.count) photos copied")
    }
  }

  /// Every rendered file of a post, when it's rendered (no I/O beyond the render row).
  func renderFiles(_ post: PlatformPost) -> [URL] {
    guard let id = post.renderId, let r = try? store.render(id: id) else { return [] }
    return r.allPaths.map { URL(fileURLWithPath: $0) }
  }
}
