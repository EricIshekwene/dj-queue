import DJQCore
import SwiftUI

/// Library quick look (DESIGN-v2 §6.6 "a quick-look sheet"): long-form, missing and removed-from-videos.json
/// clips (and Space on any clip). Plays the source file looping Eric's markers (16:9), states what is wrong and
/// offers the one fitting action as the primary.
struct LibraryQuickLook: View {
  @Bindable var model: AppModel
  let video: Video

  private var ui: BrowseUI { .shared }
  private var current: Video { model.video(video.id) ?? video }

  var body: some View {
    let v = current
    let missing = model.libraryIsMissing(v)
    let removed = model.libraryIsRemoved(v)
    let chip = model.libraryStateChip(v)
    DSDialog(model.displayName(v), description: description(v), width: 640, onClose: close) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        ZStack {
          DSVideoPreview(url: missing ? nil : model.clipURL(v), poster: model.poster(v), isActive: !missing && !model.frozen,
                         isPriority: true, loopRange: v.type == .short ? model.markerRange(v) : nil, showsScrubber: true,
                         cornerRadius: DS.radius.md, gravity: .resizeAspect)
          if missing {
            Image(systemName: "questionmark.folder").font(.system(size: 26, weight: .light)).foregroundStyle(DS.color.textTertiary)
          }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(DS.color.canvas, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
        HStack(spacing: 6) {
          if v.type == .long { DSBadge("Long-form", style: .outline, help: "A full set — uploaded by hand, never queued") }
          if missing {
            DSBadge("File missing", style: .soft(.danger), icon: "exclamationmark", help: "The source file moved or was deleted — Health › Doctor relinks it")
          } else {
            DSBadge(chip.text, style: chip.style, help: chip.tooltip)
          }
          if let s = v.score, v.type == .short { DSBadge("Score \(s)", style: .outline, help: "Your score (0–100) — it sets the posting order") }
          Spacer(minLength: 0)
        }
        if missing {
          note(.danger, "The file isn't where videos.json says.",
               "Looking again runs intake, which finds renamed or moved files by fingerprint anywhere in the session folders. Missing since: \(v.file)")
        } else if removed {
          note(.warning, "Removed from videos.json.", "Its record and history are kept. Keep posting it, or exclude it?")
        } else if v.type == .long {
          if let u = v.longformURL {
            note(.success, "Posted on YouTube.", u)
          } else {
            note(.neutral, "Not posted on YouTube yet.", "Paste the YouTube link when it's up; the file moves from Ready to Post to Posted.")
          }
        }
      }
    } footer: {
      footer(v, missing: missing, removed: removed)
    }
  }

  private func description(_ v: Video) -> String {
    [model.sessionName(v), v.part.map { "Part \($0)" }, Fmt.duration(v.type == .short ? model.clipDuration(v) : v.duration)]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private func note(_ tone: DSTone, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: tone.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tone.color).padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        Text(text).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(DS.space.sm)
    .background(DS.color.tint(tone), in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
  }

  @ViewBuilder private func footer(_ v: Video, missing: Bool, removed: Bool) -> some View {
    DSButton("Close", variant: .ghost, action: close).keyboardShortcut(.cancelAction)
    if missing {
      DSButton(v.excluded ? "Include" : "Exclude", variant: .outline,
               tooltip: v.excluded ? "Put it back into the plan" : "Keep it out of the plan while missing") { model.setExcluded([v.id], !v.excluded) }
      DSButton("Look for the file", icon: "magnifyingglass", variant: .primary,
               tooltip: "Run intake now to relink moved files") {
        model.runTick()
        close()
      }
    } else if removed {
      // Exclude is journaled (Undo restores posting); the "kept" flag that clears the warning isn't.
      DSButton("Exclude", variant: .outline, tooltip: "Stop posting it; keep its history") {
        model.setExcluded([v.id], true)
        model.keepRemoved(v.id)
        close()
      }
      DSButton("Keep posting it…", variant: .primary, tooltip: "Keep posting though it left videos.json") {
        model.confirmKeepRemoved(v) { close() }
      }
    } else if v.type == .long {
      if let u = v.longformURL, let url = URL(string: u) {
        DSButton("Copy link", icon: "link", variant: .outline) { model.copy(u); model.show("Link copied") }
        DSButton("Open on YouTube", icon: "arrow.up.right.square", variant: .primary) { NSWorkspace.shared.open(url) }
      } else {
        DSButton("Mark posted…", icon: "checkmark.circle", variant: .primary,
                 disabledReason: v.excluded ? "Excluded — include it first" : nil) {
          close()
          ui.longformTargets = [v]
        }
      }
    } else {
      DSButton("Open editor", icon: "slider.horizontal.below.rectangle", variant: .primary) {
        close()
        model.openEditor(v.id)
      }
    }
  }

  private func close() { ui.quickLook = nil }
}

/// "Mark long-form posted" (L.S4 on the design system): one empty YouTube URL field per clip. Valid links are
/// saved (PostActions.markLongformPosted moves each file Ready to Post/Longform → Posted/Longform); empty rows are
/// left as they are.
struct LongformPostedDialog: View {
  @Bindable var model: AppModel
  let videos: [Video]
  @State private var urls: [String: String] = [:]

  private var ui: BrowseUI { .shared }

  private func error(_ id: String) -> String? {
    let u = (urls[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !u.isEmpty else { return nil }
    do { try PostActions.validate(url: u, for: .youtube); return nil } catch { return error.localizedDescription }
  }

  private var ready: [(Video, String)] {
    videos.compactMap { v in
      let u = (urls[v.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return !u.isEmpty && error(v.id) == nil ? (v, u) : nil
    }
  }

  private var blocker: String? {
    if videos.contains(where: { error($0.id) != nil }) { return "Fix the links marked in red" }
    if ready.isEmpty { return videos.count == 1 ? "Paste the YouTube link first" : "Paste at least one YouTube link" }
    return nil
  }

  var body: some View {
    let one = videos.count == 1
    DSDialog(one ? "Mark long-form posted" : "Mark \(videos.count) long-form clips posted",
             description: one ? "Paste the YouTube link for “\(model.displayName(videos[0]))”. The file moves from Ready to Post to Posted."
               : "Paste each YouTube link. Clips left empty stay as they are; files move from Ready to Post to Posted.",
             icon: "play.rectangle", onClose: close) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        ForEach(videos) { v in
          DSTextField(one ? "YouTube link" : model.displayName(v), placeholder: "https://youtube.com/watch?v=…",
                      text: Binding(get: { urls[v.id] ?? "" }, set: { urls[v.id] = $0 }), icon: "link", error: error(v.id),
                      onSubmit: save)
        }
      }
    } footer: {
      DSButton("Cancel", variant: .ghost, action: close).keyboardShortcut(.cancelAction)
      DSButton(one ? "Mark posted" : "Mark \(max(ready.count, 1)) posted", variant: .primary, disabledReason: blocker,
               tooltip: "Save links; files move to Posted/Longform", shortcut: "↩", action: save)
        .keyboardShortcut(.defaultAction)
    }
  }

  private func save() {
    guard blocker == nil else { return }
    let items = ready
    let pa = model.postActions
    model.perform(items.count == 1 ? "Long-form marked posted" : "Marked \(items.count) long-form clips posted") {
      for (v, u) in items { try pa.markLongformPosted(videoId: v.id, url: u) }
    }
    close()
  }

  private func close() { ui.longformTargets = [] }
}

/// Bulk "Score…" (DESIGN-v2 §5): one number for the selected short clips → the shared confirmation sheet.
struct LibraryScoreDialog: View {
  @Bindable var model: AppModel
  let ids: [String]
  @State private var text = ""

  private var value: Int? { Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (0...100).contains($0) ? $0 : nil } }

  var body: some View {
    DSDialog("Score \(ids.count) clip\(ids.count == 1 ? "" : "s")", description: "Every selected short clip gets this score.",
             icon: "number", width: 400, onClose: close) {
      DSTextField(placeholder: "0–100", text: $text, error: !text.isEmpty && value == nil ? "Type a whole number from 0 to 100" : nil,
                  size: .lg, onSubmit: apply)
    } footer: {
      DSButton("Cancel", variant: .ghost, action: close).keyboardShortcut(.cancelAction)
      DSButton("Set score", variant: .primary, disabledReason: value == nil ? "Type a score from 0 to 100" : nil, action: apply)
        .keyboardShortcut(.defaultAction)
    }
  }

  private func apply() {
    guard let n = value else { return }
    let bulk = model.bulk
    let ids = ids
    close()
    model.requestBulk(BulkRequest(title: "Score \(ids.count) clip\(ids.count == 1 ? "" : "s") \(n)?", verb: "Set score", ids: ids,
                                  changes: [.init(field: "Score", value: "\(n)")]) { dry in
      try bulk.setScore(ids, n, dryRun: dry)
    })
  }

  private func close() { BrowseUI.shared.scoreTargets = [] }
}
