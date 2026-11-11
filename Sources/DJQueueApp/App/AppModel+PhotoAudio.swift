import AppKit
import DJQCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Round 23, photo with audio (DECISIONS-R23.md). The photo editor's Audio row, the cards' ⋯ menus, the import sheet
/// and the check script all end in `addAudio`, `changeAudio`, `removeAudio` or `importPhotos(urls:audio:title:)`, which
/// run `StillVideo` off the main thread. Nothing here sends anything to the Queue.
///
/// The state lives outside `AppModel` (extensions can't hold it): which item a video is being made for, and how far
/// along it is, for the toast and the editor's row.
@MainActor
@Observable
final class PhotoAudioUI {
  static let shared = PhotoAudioUI()
  /// The item a video is being made for now (nil = idle). One at a time.
  var busy: String?
  /// 0…1 while `busy`.
  var progress: Double = 0
  /// The last progress line shown, so a toast isn't rewritten for every sample of ffmpeg's output.
  @ObservationIgnored var shownPercent = -1
  /// The last made or changed item, for scripted runs.
  var lastVideo: String?
  /// The last failure's words, for scripted runs.
  var lastError: String?
  /// The audio file's length, read once per file for the import sheet's row.
  var lengths: [URL: Double] = [:]
  /// For scripted runs, which can't open a file picker: what the last picker was asked for (an item's id, or "import"),
  /// and every progress line said since it was last emptied.
  @ObservationIgnored var asked: String?
  @ObservationIgnored var said: [String] = []

  /// "Making the video… 40 %".
  var line: String { Self.line(progress) }
  nonisolated static func line(_ p: Double) -> String { "Making the video… \(Int((min(1, max(0, p)) * 100).rounded())) %" }
}

extension AppModel {
  // MARK: What can be done

  /// Why audio can't be added to, changed on or removed from `v` now (nil = it can). Core's words (D3, D9).
  func audioBlocker(_ v: Video) -> String? {
    if PhotoAudioUI.shared.busy != nil { return "Still making the last video" }
    return (try? StillVideo(store: store).blocker(v)) ?? nil
  }

  /// The audio file types the picker offers (`StillVideo.audioExtensions`).
  nonisolated static var audioTypes: [UTType] { StillVideo.audioExtensions.sorted().compactMap { UTType(filenameExtension: $0) } }

  /// "Friday mix.mp3 · 3:02".
  nonisolated static func audioLine(_ s: StillSource) -> String { "\(s.audioName) · \(Fmt.duration(s.audioDuration))" }

  // MARK: Picking

  /// The system file picker for one audio file. A real panel lands on a display, so a snapshot or scripted run never
  /// opens it: checks call the function the pick ends in.
  private func pickAudio(_ title: String, _ message: String, then: @escaping (URL) -> Void) {
    guard !Self.isSnapshotRun else { return }
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = "Choose"
    panel.message = message
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = Self.audioTypes
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in then(url) }
    }
  }

  /// "Add audio…" on a photo post: pick the file, then make the video.
  func askAddAudio(to id: String) {
    guard let v = video(id) else { return }
    if let why = audioBlocker(v) { show(why, error: true); return }
    PhotoAudioUI.shared.asked = id
    pickAudio("Add audio", "Pick the audio. The photo becomes a video as long as it is.") { [weak self] url in self?.addAudio(to: id, audio: url) }
  }

  /// "Change audio…" on a made video.
  func askChangeAudio(_ id: String) {
    guard let v = video(id) else { return }
    if let why = audioBlocker(v) { show(why, error: true); return }
    PhotoAudioUI.shared.asked = id
    pickAudio("Change audio", "Pick the new audio. The video is made again with it.") { [weak self] url in self?.changeAudio(videoId: id, audio: url) }
  }

  /// "Choose audio…" in the import sheet.
  func askImportAudio() {
    PhotoAudioUI.shared.asked = "import"
    pickAudio("Choose audio", "Each photo becomes a video with this audio.") { [weak self] url in self?.setImportAudio(url) }
  }

  /// Puts an audio file on the open import sheet (nil takes it off). A file that can't be the audio is refused in a
  /// toast, in Core's words, and the sheet keeps what it had.
  func setImportAudio(_ url: URL?) {
    guard photoImportRequest != nil else { return }
    guard let url else { photoImportRequest?.audio = nil; return }
    Task.detached(priority: .userInitiated) {
      let out = Result { try StillVideo.audioSeconds(url) }
      await MainActor.run {
        switch out {
        case .success(let d):
          PhotoAudioUI.shared.lengths[url] = d
          self.photoImportRequest?.audio = url
        case .failure(let e):
          self.show(DSToastModel(message: "That audio can't be used", detail: e.localizedDescription, tone: .danger, duration: 8))
        }
      }
    }
  }

  // MARK: Add, change, remove

  /// THE "Add audio": turns a one-photo post into a video with this audio, in place (`StillVideo.addAudio`), off the
  /// main thread, with its progress in a toast and in the editor's row. Then it reloads, says "Now a video with audio"
  /// with Undo, and an editor open on the item goes on as the clip editor. Nothing is sent to the Queue.
  func addAudio(to id: String, audio: URL) {
    makeVideo(id, said: "Now a video with audio", label: "Add audio") { s, progress in
      try StillVideo(store: s).addAudio(to: id, audio: audio, progress: progress)
    }
  }

  /// "Change audio…": the video is made again with another file.
  func changeAudio(videoId id: String, audio: URL) {
    makeVideo(id, said: "Audio changed", label: "Change audio") { s, progress in
      try StillVideo(store: s).changeAudio(videoId: id, audio: audio, progress: progress)
    }
  }

  /// "Remove audio": a photo post again. No file is made, so it lands at once.
  func removeAudio(videoId id: String) {
    guard let v = video(id) else { return }
    if let why = audioBlocker(v) { show(why, error: true); return }
    splitEditorSession()
    let s = store
    Task.detached(priority: .userInitiated) {
      let out = Result { try StillVideo(store: s).removeAudio(videoId: id) }
      await MainActor.run { self.audioLanded(id, out, said: "Audio removed · a photo post again", label: "Remove audio") }
    }
  }

  private func makeVideo(_ id: String, said: String, label: String,
                         _ work: @escaping @Sendable (Store, @escaping @Sendable (Double) -> Void) throws -> StillVideo.Change) {
    guard let v = video(id) else { return }
    if let why = audioBlocker(v) { show(why, error: true); return }
    let ui = PhotoAudioUI.shared
    // The editor's edits so far are their own entry, so the history reads Edits → Add audio → Edits (`splitEditorSession`
    // also lands the open editor's pending writes before the row changes under it).
    splitEditorSession()
    ui.busy = id
    ui.progress = 0
    ui.shownPercent = -1
    ui.lastError = nil
    sayProgress(0)
    let s = store
    Task.detached(priority: .userInitiated) {
      let out = Result { try work(s) { p in Task { @MainActor in self.sayProgress(p) } } }
      await MainActor.run { self.audioLanded(id, out, said: said, label: label) }
    }
  }

  /// One toast that counts up, rewritten only when the whole percent changes.
  private func sayProgress(_ p: Double) {
    let ui = PhotoAudioUI.shared
    guard ui.busy != nil else { return }
    ui.progress = max(ui.progress, p)
    let percent = Int((ui.progress * 100).rounded())
    guard percent != ui.shownPercent else { return }
    ui.shownPercent = percent
    ui.said.append(PhotoAudioUI.line(ui.progress))
    show(DSToastModel(message: PhotoAudioUI.line(ui.progress), tone: .neutral, duration: nil))
  }

  private func audioLanded(_ id: String, _ out: Result<StillVideo.Change, Error>, said: String, label: String) {
    let ui = PhotoAudioUI.shared
    ui.busy = nil
    switch out {
    case .failure(let e):
      ui.lastError = e.localizedDescription
      refresh()
      show(DSToastModel(message: label == "Remove audio" ? "The audio wasn't removed" : "The video wasn't made", detail: e.localizedDescription,
                        tone: .danger, duration: 8))
    case .success(let change):
      ui.lastVideo = change.video.id
      ChangeSignal.post()
      // Its cover, proxy and stamps belong to what it was a moment ago.
      proxyURLs[id] = nil
      refreshPreviewStamps([id])
      refresh()
      if let b = change.batchId { undoHistory.push(b, label: label) }
      let detail = change.video.still.map(Self.audioLine)
      show(DSToastModel(message: said, detail: detail, tone: .success, actionTitle: change.batchId == nil ? nil : "Undo",
                        action: change.batchId.map { b in { [weak self] in self?.undo(batch: b) } }, duration: 8))
      reloadOpenEditor(id)
    }
  }

  /// An editor open on `id` reads the item again: after audio is added it goes on as the clip editor, after it is
  /// removed as the photo editor. The editor stays open on the same item, and its session carries on after the change.
  func reloadOpenEditor(_ id: String) {
    guard editor != nil, let live = EditorModel.live, live.videoId == id else { return }
    live.load(id)
  }

  /// After an undo: an item that went from photo post to video or back (or to another audio) gets fresh previews, and
  /// an editor open on it reads it again.
  func audioUndone(_ r: BulkResult) {
    for id in r.changed {
      guard let now = try? store.video(id: id), let was = videoById[id], now.isPhoto != was.isPhoto || now.still != was.still else { continue }
      proxyURLs[id] = nil
      refreshPreviewStamps([id])
      reloadOpenEditor(id)
    }
  }

  // MARK: Import with audio

  /// The import sheet with an audio file chosen: a video per photo, each with that audio (`StillVideo.add`), in Edit.
  /// The same rules as `importPhotos`: one at a time, the sheet stays open on a failure, nothing goes to the Queue.
  func importPhotos(urls: [URL], audio: URL, title: String?) {
    let ui = PhotoImportUI.shared, audioUI = PhotoAudioUI.shared
    guard !urls.isEmpty else { return }
    if ui.importing || audioUI.busy != nil {
      show(DSToastModel(message: "Still adding the last photos", detail: "Try again when they are in", duration: 4))
      return
    }
    ui.importing = true
    audioUI.busy = "import"
    audioUI.progress = 0
    audioUI.shownPercent = -1
    audioUI.lastError = nil
    let s = store
    let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let given = name?.isEmpty == false ? name : nil
    Task.detached(priority: .userInitiated) {
      let out = Result { try StillVideo(store: s).add(photos: urls, audio: audio, title: given, titleSource: "app") { p in
        Task { @MainActor in if PhotoAudioUI.shared.busy != nil { PhotoAudioUI.shared.progress = max(PhotoAudioUI.shared.progress, p) } }
      } }
      await MainActor.run { self.importedWithAudio(out) }
    }
  }

  private func importedWithAudio(_ out: Result<StillVideo.AddResult, Error>) {
    let ui = PhotoImportUI.shared
    ui.importing = false
    PhotoAudioUI.shared.busy = nil
    switch out {
    case .failure(let e):
      ui.lastPosts = []
      PhotoAudioUI.shared.lastError = e.localizedDescription
      refresh()
      show(DSToastModel(message: "The videos weren't made", detail: e.localizedDescription, tone: .danger, duration: 8))
    case .success(let r):
      photoImportRequest = nil
      ui.lastPosts = r.videos.map(\.id)
      ui.lastSkipped = r.skipped
      ChangeSignal.post()
      refresh()
      let skipped = r.skipped.isEmpty ? nil : Self.skippedText(r.skipped)
      guard let first = r.videos.first else {
        show(DSToastModel(message: "No videos made", detail: skipped, tone: .danger, duration: 8))
        return
      }
      let ids = r.videos.map(\.id)
      show(DSToastModel(message: r.videos.count == 1 ? "Added 1 video to Edit" : "Added \(r.videos.count) videos to Edit",
                        detail: [first.still.map(Self.audioLine), skipped].compactMap { $0 }.joined(separator: "\n"),
                        tone: .success, actionTitle: "Open", action: { [weak self] in self?.openEditor(first.id, in: ids) },
                        duration: r.skipped.isEmpty ? 6 : 10))
    }
  }

  /// What the sheet makes with audio chosen: "1 video with this audio" · "3 videos, each with this audio".
  nonisolated static func importPlanWithAudio(count: Int) -> String {
    count == 1 ? "1 video with this audio" : "\(count) videos, each with this audio"
  }
}

/// "Add audio…" on a photo post's ⋯ and right-click menu, "Change audio…" and "Remove audio" on a made video's.
/// Native items show no tooltip, so one that is off says why in its title.
struct AudioMenuItems: View {
  @Bindable var model: AppModel
  let video: Video

  var body: some View {
    let why = model.audioBlocker(video).map { $0.prefix(1).lowercased() + $0.dropFirst() }
    if video.isPhoto {
      Button(why.map { "Add audio — \($0)" } ?? "Add audio…", systemImage: "music.note") { model.askAddAudio(to: video.id) }
        .disabled(why != nil)
    } else if video.isStill {
      Button(why.map { "Change audio — \($0)" } ?? "Change audio…", systemImage: "music.note") { model.askChangeAudio(video.id) }
        .disabled(why != nil)
      Button(why == nil ? "Remove audio" : "Remove audio — it can't change now", systemImage: "speaker.slash") { model.removeAudio(videoId: video.id) }
        .disabled(why != nil)
    }
  }
}
