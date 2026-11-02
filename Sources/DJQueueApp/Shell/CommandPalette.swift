import DJQCore
import SwiftUI

struct PaletteCommand: Identifiable {
  let id: String
  let title: String
  let symbol: String
  var hint: String? = nil
  var group = "Actions"
  /// Shown greyed with this reason; not runnable.
  var disabled: String? = nil
  let run: () -> Void
}

extension AppModel {
  /// Every action (INVENTORY APP.CMD), contextual to the selected video / post.
  var commands: [PaletteCommand] {
    var c: [PaletteCommand] = []
    for s in Screen.allCases {
      c.append(.init(id: "go.\(s.rawValue)", title: "Go to \(s.title)", symbol: s.symbol, hint: "⌘\(s.key.character)", group: "Go to") { [weak self] in
        self?.screen = s
      })
    }
    c.append(.init(id: "go.settings", title: "Open Settings", symbol: "gearshape", hint: "⌘,", group: "Go to") {
      WindowManager.shared.showSettings()
    })

    if let v = focusedVideo {
      let name = displayName(v)
      c.append(.init(id: "video.edit", title: "Edit “\(name)”", symbol: "slider.horizontal.below.rectangle", hint: "⌘E") { [weak self] in
        self?.openEditor(v.id, in: self?.selectedVideoIds)
      })
      c.append(.init(id: "video.preview", title: "Preview “\(name)”", symbol: "play.rectangle", hint: "Space") { [weak self] in
        self?.previewVideo = v
      })
      c.append(.init(id: "video.postToday", title: "Post “\(name)” today", symbol: "bolt") { [weak self] in self?.postToday(v.id) })
      c.append(.init(id: "video.pinTomorrow", title: "Pin “\(name)” to tomorrow", symbol: "pin") { [weak self] in
        guard let self else { return }
        self.pin(v.id, dayKey: self.dm.addDays(self.todayKey, 1))
      })
      c.append(.init(id: "video.setScore", title: "Set score of “\(name)”…", symbol: "number") { [weak self] in self?.scorePrompt = v })
      c.append(.init(id: "video.pinDate", title: "Pin “\(name)” to date…", symbol: "calendar") { [weak self] in self?.pinPrompt = v })
      let notPlanned = nextSlotByVideo[v.id] == nil ? "Not planned — order follows score; change the score to move it" : nil
      c.append(.init(id: "video.moveUp", title: "Move up", symbol: "arrow.up", disabled: notPlanned ?? (neighbourSlot(v.id, -1) == nil ? "Already first" : nil)) {
        [weak self] in self?.moveVideo(v.id, by: -1)
      })
      c.append(.init(id: "video.moveDown", title: "Move down", symbol: "arrow.down", disabled: notPlanned ?? (neighbourSlot(v.id, 1) == nil ? "Already last" : nil)) {
        [weak self] in self?.moveVideo(v.id, by: 1)
      })
      c.append(.init(id: "video.skipNext", title: "Skip next slot of “\(name)”", symbol: "forward.end") { [weak self] in self?.skipNext(v.id) })
      c.append(.init(id: "video.exclude", title: v.excluded ? "Include “\(name)”" : "Exclude “\(name)”", symbol: v.excluded ? "plus.circle" : "minus.circle") { [weak self] in
        self?.setExcluded([v.id], !v.excluded)
      })
      c.append(.init(id: "video.duplicateVersion", title: "Duplicate latest version", symbol: "plus.square.on.square") { [weak self] in
        self?.duplicateVersion(v.id)
      })
      c.append(.init(id: "video.rerender", title: "Re-render", symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.reRender(v.id) })
      for p in settings.activePlatforms where repostBlocker(v.id, p) == nil {
        c.append(.init(id: "video.repost.\(p.rawValue)", title: "Repost on \(p.displayName)", symbol: "arrow.uturn.forward") { [weak self] in
          self?.repost(v.id, p)
        })
      }
      for k in Kind.allCases where k != v.kind {
        c.append(.init(id: "video.kind.\(k.rawValue)", title: "Set kind: \(k.displayName)", symbol: "tag") { [weak self] in self?.setKind([v.id], k) })
      }
      if v.type == .long {
        c.append(.init(id: "video.longform", title: "Mark long-form posted…", symbol: "checkmark.circle") { [weak self] in self?.longformTarget = v })
      }
    }

    let thisWeek = planner.weekStart(for: now)
    let nextWeek = dm.addDays(thisWeek, 7)
    c.append(.init(id: "week.approveNext", title: "Approve next week", symbol: "checkmark.seal", hint: "⌘↩") { [weak self] in self?.approveWeek(nextWeek) })
    if weekStates[nextWeek] != .approved {
      c.append(.init(id: "week.proposeNext", title: "Propose next week", symbol: "wand.and.stars") { [weak self] in self?.proposeWeek(nextWeek) })
    }
    c.append(.init(id: "week.rebuild", title: "Rebuild next week", symbol: "arrow.clockwise") { [weak self] in self?.rebuildWeek(nextWeek) })
    c.append(.init(id: "week.push", title: "Push plan by a day", symbol: "calendar.badge.clock") { [weak self] in self?.pushPlan(days: 1) })

    c.append(.init(id: "post.pauseAll", title: settings.paused ? "Resume all posting" : "Pause all posting",
                   symbol: settings.paused ? "play.circle" : "pause.circle") { [weak self] in
      guard let self else { return }
      if self.settings.paused { self.setPaused(false) } else { self.confirmPause = true }
    })
    for p in settings.activePlatforms {
      let paused = settings.pausedPlatforms.contains(p)
      c.append(.init(id: "post.pause.\(p.rawValue)", title: paused ? "Resume \(p.displayName)" : "Pause \(p.displayName)",
                     symbol: paused ? "play" : "pause") { [weak self] in self?.setPlatformPaused(p, !paused) })
    }

    let post = postsSelection.flatMap { id in posts.first { $0.id == id } } ?? highlightPostId.flatMap { id in posts.first { $0.id == id } }
    if let post {
      let n = "\(post.platform.shortName) · \(video(post.videoId).map(displayName) ?? "")"
      if !post.state.isTerminal {
        c.append(.init(id: "post.markPosted", title: "Mark posted… (\(n))", symbol: "checkmark.circle") { [weak self] in self?.markPostedTarget = post })
      }
      if !post.state.isTerminal || post.state == .posted {
        c.append(.init(id: "post.report", title: "Mark failed / report problem… (\(n))", symbol: "exclamationmark.bubble") { [weak self] in
          self?.reportTarget = post
        })
      }
      if canReset(post) {
        c.append(.init(id: "post.reset", title: "Reset post (\(n))", symbol: "arrow.counterclockwise") { [weak self] in self?.reset(post) })
      }
      if canSkip(post) {
        c.append(.init(id: "post.skip", title: "Skip post (\(n))", symbol: "forward") { [weak self] in self?.skip(post) })
      }
      if post.state == .overdue {
        c.append(.init(id: "post.postNow", title: "Post now (\(n))", symbol: "bolt") { [weak self] in self?.postNow(post) })
        c.append(.init(id: "post.shiftPlan", title: "Shift plan (\(n))", symbol: "calendar.badge.clock") { [weak self] in self?.shiftPlan(post) })
      }
    }
    c.append(.init(id: "post.review", title: "Review problems", symbol: "exclamationmark.octagon") { [weak self] in self?.reviewProblems() })

    c.append(.init(id: "health.doctor", title: "Open Doctor", symbol: "stethoscope") { [weak self] in
      self?.screen = .health
      self?.runDoctor()
    })
    c.append(.init(id: "health.copyReport", title: "Copy Doctor report", symbol: "doc.on.clipboard") { [weak self] in
      guard let self else { return }
      if self.doctorReport == nil { self.doctorReport = Doctor(store: self.store).run() }
      self.copyDoctorReport()
    })
    c.append(.init(id: "health.tick", title: "Run engine tick now", symbol: "bolt.horizontal.circle") { [weak self] in self?.runTick() })
    c.append(.init(id: "health.log", title: "Open engine log", symbol: "doc.text") { [weak self] in self?.openLog() })
    c.append(.init(id: "help.shortcuts", title: "Keyboard shortcuts", symbol: "keyboard", hint: "⌘/") { [weak self] in self?.showShortcuts = true })
    return c
  }
}

/// APP.CMD (ref Magnific): 640 pt panel, Recents + Actions, shortcut hints right-aligned.
struct CommandPalette: View {
  @Bindable var model: AppModel
  @State private var query = ""
  @State private var index = 0
  @FocusState private var focused: Bool

  private var all: [PaletteCommand] { model.commands }

  private var sections: [(String, [PaletteCommand])] {
    let cmds = all
    if !query.isEmpty {
      let q = query.lowercased()
      return [("Results", cmds.filter { $0.title.lowercased().contains(q) || $0.id.lowercased().contains(q) })]
    }
    let recents = model.recentCommands.compactMap { id in cmds.first { $0.id == id } }
    var out: [(String, [PaletteCommand])] = []
    if !recents.isEmpty { out.append(("Recents", recents)) }
    let groups = ["Actions", "Go to"]
    for g in groups { out.append((g == "Actions" ? "Quick actions" : g, cmds.filter { $0.group == g })) }
    return out
  }

  private var flat: [PaletteCommand] { sections.flatMap(\.1) }

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { close() }
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Type a command or search…", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .focused($focused)
            .onSubmit { runSelected() }
            .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
            .onKeyPress(.downArrow) { index = min(flat.count - 1, index + 1); return .handled }
            .onExitCommand { close() }
          KeyHint("⌘K")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        Divider()
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 2) {
              let flatIds = flat.map(\.id)
              ForEach(sections, id: \.0) { section in
                Eyebrow(section.0).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                ForEach(section.1) { cmd in
                  let i = flatIds.firstIndex(of: cmd.id) ?? -1
                  row(cmd, selected: i == index)
                    .id("\(section.0).\(cmd.id)")
                    .onTapGesture { run(cmd) }
                }
              }
              if flat.isEmpty {
                Text("No matching command").foregroundStyle(.secondary).padding(20)
              }
            }
            .padding(8)
          }
          .frame(maxHeight: 420)
          .onChange(of: index) { _, i in
            if i < flat.count, let s = sections.first(where: { $0.1.contains { $0.id == flat[i].id } }) {
              proxy.scrollTo("\(s.0).\(flat[i].id)")
            }
          }
        }
        Divider()
        HStack(spacing: 16) {
          footer("↑ ↓", "Navigate")
          footer("↩", "Select")
          footer("Esc", "Close")
          Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
      }
      .frame(width: 640)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
      .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
      .padding(.top, 90)
    }
    .onAppear { focused = true; index = 0 }
    .onChange(of: query) { index = 0 }
  }

  private func row(_ c: PaletteCommand, selected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: c.symbol)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 26, height: 26)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
      Text(c.title).font(.system(size: 14)).lineLimit(1).foregroundStyle(c.disabled == nil ? .primary : .tertiary)
      if let why = c.disabled { Text(why).font(DS.Font.secondary).foregroundStyle(.tertiary).lineLimit(1) }
      Spacer()
      if let h = c.hint { KeyHint(h) }
      if selected { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary) }
    }
    .padding(.horizontal, 6)
    .frame(height: 38)
    .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
  }

  private func footer(_ k: String, _ t: String) -> some View {
    HStack(spacing: 5) {
      KeyHint(k)
      Text(t).font(DS.Font.secondary).foregroundStyle(.secondary)
    }
  }

  private func runSelected() {
    guard index < flat.count else { return }
    run(flat[index])
  }

  private func run(_ c: PaletteCommand) {
    if let why = c.disabled { model.show(why, error: true); return }
    model.noteCommand(c.id)
    close()
    c.run()
  }

  private func close() {
    model.showPalette = false
    query = ""
  }
}

// MARK: - APP.CTX shared context menus

struct VideoContextMenu: View {
  @Bindable var model: AppModel
  let video: Video
  var ids: [String] = []

  var body: some View {
    let targets = ids.count > 1 && ids.contains(video.id) ? ids : [video.id]
    if targets.count == 1 {
      Button("Edit", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(video.id, in: model.selectedVideoIds) }
      Button("Preview", systemImage: "play.rectangle") { model.previewVideo = video }
      Divider()
      Button("Post today", systemImage: "bolt") { model.postToday(video.id) }
      Button("Pin to tomorrow", systemImage: "pin") { model.pin(video.id, dayKey: model.dm.addDays(model.todayKey, 1)) }
      Button("Skip next slot", systemImage: "forward.end") { model.skipNext(video.id) }
      RepostMenu(model: model, videoId: video.id)
      Divider()
      Button("Duplicate version", systemImage: "plus.square.on.square") { model.duplicateVersion(video.id) }
      Button("Re-render", systemImage: "arrow.triangle.2.circlepath") { model.reRender(video.id) }
    } else {
      Button("Add \(targets.count) to week", systemImage: "calendar.badge.plus") { model.addToWeek(targets) }
    }
    Menu("Kind") {
      ForEach(Kind.allCases, id: \.self) { k in Button(k.displayName) { model.setKind(targets, k) } }
    }
    Menu("Score") {
      ForEach([90, 80, 70, 60, 50, 40, 30], id: \.self) { s in Button("\(s)") { model.setScore(targets, s) } }
      Button("Clear") { model.setScore(targets, nil) }
    }
    Divider()
    Button(video.excluded ? "Include" : "Exclude", systemImage: video.excluded ? "plus.circle" : "minus.circle") {
      model.setExcluded(targets, !video.excluded)
    }
  }
}

struct PostContextMenu: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    if !post.state.isTerminal {
      Button("Mark posted…", systemImage: "checkmark.circle") { model.markPostedTarget = post }
      Button("Copy caption", systemImage: "text.quote") { model.copyCaption(post) }
      if post.platform == .youtube { Button("Copy title", systemImage: "textformat") { model.copyTitle(post) } }
      Button("Open upload page", systemImage: "safari") { model.openUploadPage(post) }
      Button("Reveal in Finder", systemImage: "folder") { model.revealFile(post) }
      Button("Copy file", systemImage: "doc.on.doc") { model.copyFile(post) }
      Divider()
    }
    if !post.state.isTerminal || post.state == .posted {
      Button("Report problem…", systemImage: "exclamationmark.bubble") { model.reportTarget = post }
    }
    if post.state == .overdue {
      Button("Post now", systemImage: "bolt") { model.postNow(post) }
      Button("Shift plan", systemImage: "calendar.badge.clock") { model.shiftPlan(post) }
    }
    if model.canReset(post) { Button("Reset post", systemImage: "arrow.counterclockwise") { model.reset(post) } }
    if model.canSkip(post) { Button("Skip this platform", systemImage: "forward") { model.skip(post) } }
    if let v = model.video(post.videoId) {
      Divider()
      Button("Edit video", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(v.id) }
    }
  }
}

/// Repost needs the next version to exist (PostActions.repost); blocked platforms show why.
struct RepostMenu: View {
  @Bindable var model: AppModel
  let videoId: String
  var body: some View {
    Menu("Repost on") {
      ForEach(model.settings.activePlatforms) { p in
        if let why = model.repostBlocker(videoId, p) {
          Button("\(p.displayName) — \(why)") {}.disabled(true)
        } else {
          Button(p.displayName) { model.repost(videoId, p) }
        }
      }
    }
  }
}

/// ⌘K "Set score…": one big number field.
struct ScorePromptSheet: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var text = ""
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Score “\(model.displayName(video))”").font(DS.Font.title)
      TextField("0–100", text: $text)
        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
        .textFieldStyle(.roundedBorder)
        .onSubmit(save)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(Int(text).map { !(0...100).contains($0) } ?? true)
      }
    }
    .padding(22)
    .frame(width: 360)
    .onAppear { text = video.score.map(String.init) ?? "" }
  }
  private func save() {
    guard let n = Int(text), (0...100).contains(n) else { return }
    model.setScore([video.id], n)
    dismiss()
  }
}

/// ⌘K "Pin to date…".
struct PinPromptSheet: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var date = Date()
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pin “\(model.displayName(video))”").font(DS.Font.title)
      DatePicker("Date", selection: $date, in: model.now..., displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Pin") { model.pin(video.id, date: date); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
  }
}
