import DJQCore
import SwiftUI

/// One ⌘K row: an action, a clip (opens its action page) or a destination.
struct PaletteCommand: Identifiable {
  let id: String
  let title: String
  let symbol: String
  /// Right-aligned shortcut text ("⌘3").
  var hint: String? = nil
  var group = "Actions"
  /// Second line (clip rows: session · state).
  var subtitle: String? = nil
  /// Shown greyed with this reason; not runnable.
  var disabled: String? = nil
  /// Keeps the palette open (clip rows open the clip's action page).
  var keepsOpen = false
  let run: () -> Void
}

// MARK: - Commands

extension AppModel {
  /// Destinations: every screen (⌘1…⌘8) and Settings.
  var paletteGoTo: [PaletteCommand] {
    Screen.allCases.map { s in
      PaletteCommand(id: "go.\(s.rawValue)", title: "Go to \(s.title)", symbol: s.symbol, hint: "⌘\(s.key.character)", group: "Go to") {
        [weak self] in
        self?.editor = nil
        self?.screen = s
      }
    } + [PaletteCommand(id: "go.settings", title: "Open Settings", symbol: "gearshape", hint: "⌘,", group: "Go to") { [weak self] in
      self?.showSettings = true
    }]
  }

  /// Screen-independent actions, plus the selection's (one clip → its page; clips → agent prompt; a post → its actions).
  var paletteActions: [PaletteCommand] {
    var c: [PaletteCommand] = []
    if let v = focusedVideo {
      c.append(paletteClipRow(v, title: "Actions for “\(displayName(v))”"))
    }
    let shorts = selectedVideoIds.compactMap(video).filter { $0.type == .short }.map(\.id)
    let queued = selectedVideoIds.compactMap(video).filter { [.queue, .scheduled].contains(ClipStage.of($0)) && !$0.heldInEdit }.map(\.id)
    if !queued.isEmpty {
      let blocked = removeFromQueueBlocker(queued)
      c.append(.init(id: "selection.unqueue", title: "Remove \(queued.count) from queue", symbol: "arrow.uturn.backward",
                     subtitle: blocked == nil ? Self.removeFromQueueHelp : nil, disabled: blocked) { [weak self] in
        self?.removeFromQueue(queued)
      })
    }
    if shorts.count > 1 {
      c.append(.init(id: "selection.stageBack", title: "Move \(shorts.count) back a stage", symbol: "chevron.left") { [weak self] in
        self?.stageBack(shorts)
      })
      c.append(.init(id: "selection.stageForward", title: "Move \(shorts.count) forward a stage", symbol: "chevron.right") { [weak self] in
        self?.stageForward(shorts)
      })
    }
    if !shorts.isEmpty {
      c.append(.init(id: "selection.agentPrompt", title: "Copy agent prompt for \(shorts.count) clip\(shorts.count == 1 ? "" : "s")",
                     symbol: "text.bubble") { [weak self] in self?.copyAgentPrompt(shorts) })
    }
    c.append(.init(id: "post.pauseAll", title: settings.paused ? "Resume all posting" : "Pause all posting",
                   symbol: settings.paused ? "play.circle" : "pause.circle") { [weak self] in
      guard let self else { return }
      if self.settings.paused { self.setPaused(false) } else { self.confirmPause = true }
    })
    if !problems.isEmpty {
      c.append(.init(id: "post.review", title: "Review \(problems.count) problem\(problems.count == 1 ? "" : "s")", symbol: "exclamationmark.octagon") {
        [weak self] in self?.reviewProblems()
      })
    }

    let nextWeek = dm.addDays(planner.weekStart(for: now), 7)
    c.append(.init(id: "week.approveNext", title: "Approve next week", symbol: "checkmark.seal", hint: "⌘↩",
                   disabled: weekStates[nextWeek] == .approved ? "Next week is already approved" : nil) { [weak self] in self?.approveWeek(nextWeek) })
    if weekStates[nextWeek] != .approved {
      c.append(.init(id: "week.proposeNext", title: "Propose next week", symbol: "wand.and.stars") { [weak self] in self?.proposeWeek(nextWeek) })
    }
    c.append(.init(id: "week.rebuild", title: "Rebuild next week", symbol: "arrow.clockwise") { [weak self] in self?.rebuildWeek(nextWeek) })
    c.append(.init(id: "week.push", title: "Push plan by a day", symbol: "calendar.badge.clock") { [weak self] in self?.pushPlan(days: 1) })

    for p in settings.activePlatforms {
      let paused = settings.pausedPlatforms.contains(p)
      c.append(.init(id: "post.pause.\(p.rawValue)", title: paused ? "Resume \(p.displayName)" : "Pause \(p.displayName)",
                     symbol: paused ? "play" : "pause") { [weak self] in self?.setPlatformPaused(p, !paused) })
    }

    let post = postsSelection.flatMap { id in posts.first { $0.id == id } } ?? highlightPostId.flatMap { id in posts.first { $0.id == id } }
    if let post {
      let n = "\(post.platform.displayName) · \(video(post.videoId).map(displayName) ?? "")"
      if !post.state.isTerminal {
        c.append(.init(id: "post.markPosted", title: "Mark posted… (\(n))", symbol: "checkmark.circle") { [weak self] in self?.markPostedTarget = post })
      }
      if !post.state.isTerminal || post.state == .posted {
        c.append(.init(id: "post.report", title: "Report problem… (\(n))", symbol: "exclamationmark.bubble") { [weak self] in
          self?.reportTarget = post
        })
      }
      c.append(.init(id: "post.reset", title: "Reset post (\(n))", symbol: "arrow.counterclockwise",
                     disabled: canReset(post) ? nil : heldReason(post.videoId) ?? "Its time has passed or it's still planned") { [weak self] in self?.reset(post) })
      c.append(.init(id: "post.skip", title: "Skip post (\(n))", symbol: "forward",
                     disabled: canSkip(post) ? nil : "Already \(post.state.displayName.lowercased())") { [weak self] in self?.skip(post) })
      if post.state == .overdue {
        let held = heldReason(post.videoId)
        c.append(.init(id: "post.postNow", title: "Post now (\(n))", symbol: "bolt", disabled: held) { [weak self] in self?.postNow(post) })
        c.append(.init(id: "post.shiftPlan", title: "Shift plan (\(n))", symbol: "calendar.badge.clock", disabled: held) { [weak self] in
          self?.shiftPlan(post)
        })
      }
    }

    c.append(.init(id: "health.tick", title: "Run engine tick now", symbol: "bolt.horizontal.circle") { [weak self] in self?.runTick() })
    c.append(.init(id: "health.doctor", title: "Open Doctor", symbol: "stethoscope") { [weak self] in
      self?.screen = .health
      self?.runDoctor()
    })
    c.append(.init(id: "health.copyReport", title: "Copy Doctor report", symbol: "doc.on.clipboard") { [weak self] in
      guard let self else { return }
      if self.doctorReport == nil { self.doctorReport = Doctor(store: self.store).run() }
      self.copyDoctorReport()
    })
    c.append(.init(id: "health.log", title: "Open engine log", symbol: "doc.text") { [weak self] in self?.openLog() })
    c.append(.init(id: "help.shortcuts", title: "Keyboard shortcuts", symbol: "keyboard", hint: "⌘/") { [weak self] in self?.showShortcuts = true })
    return c
  }

  /// A clip as a palette row: opens its action page.
  func paletteClipRow(_ v: Video, title: String? = nil) -> PaletteCommand {
    let chip = libraryIsMissing(v) ? "File missing" : libraryStateChip(v).text
    let meta = [sessionName(v), v.type == .long ? "Long-form" : v.score.map { "Score \($0)" }, chip].compactMap { $0 }.filter { !$0.isEmpty }
    return PaletteCommand(id: "clip.\(v.id)", title: title ?? displayName(v), symbol: v.type == .long ? "rectangle" : "rectangle.portrait",
                          hint: "Actions ›", group: "Clips", subtitle: meta.joined(separator: " · "), keepsOpen: true) {
      BrowseUI.shared.paletteClipId = v.id
      BrowseUI.shared.paletteQuery = ""
    }
  }

  /// Clips whose display name (or raw tag) contains `q`, best first: prefix matches, then the rest.
  func paletteClips(matching q: String, limit: Int = 6) -> [Video] {
    let q = q.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    let hits = videos.filter { displayName($0).localizedCaseInsensitiveContains(q) || $0.tag.localizedCaseInsensitiveContains(q) }
    let prefix = hits.filter { displayName($0).lowercased().hasPrefix(q.lowercased()) }
    let rest = hits.filter { !displayName($0).lowercased().hasPrefix(q.lowercased()) }
    return Array((prefix + rest).prefix(limit))
  }

  /// One clip's actions (the palette's second page): open, score, pin, move, exclude, agent prompt, kind, render…
  func paletteClipCommands(_ v: Video) -> [PaletteCommand] {
    let name = displayName(v)
    let short = v.type == .short
    let missing = libraryIsMissing(v)
    let longWhy = short ? nil : "Long-form clips have no score or plan"
    var c: [PaletteCommand] = []
    c.append(.init(id: "clip.\(v.id).edit", title: "Open in editor", symbol: "slider.horizontal.below.rectangle", hint: "⌘E",
                   disabled: !short ? "Long-form clips aren't edited here" : missing ? "File missing — relink it first" : nil) { [weak self] in
      self?.openEditor(v.id)
    })
    c.append(.init(id: "clip.\(v.id).preview", title: "Quick look", symbol: "eye", hint: "Space",
                   disabled: missing ? "File missing" : nil) { [weak self] in self?.previewVideo = v })
    c.append(.init(id: "clip.\(v.id).score", title: v.score == nil ? "Set score…" : "Change score (\(v.score!))…", symbol: "number",
                   disabled: longWhy) { [weak self] in self?.scorePrompt = v })
    c.append(.init(id: "clip.\(v.id).pinDate", title: "Pin to date…", symbol: "calendar", disabled: longWhy ?? (v.excluded ? "Excluded" : nil)) {
      [weak self] in self?.pinPrompt = v
    })
    c.append(.init(id: "clip.\(v.id).pinTomorrow", title: "Pin to tomorrow", symbol: "pin", disabled: longWhy ?? (v.excluded ? "Excluded" : nil)) {
      [weak self] in
      guard let self else { return }
      self.pin(v.id, dayKey: self.dm.addDays(self.todayKey, 1))
    })
    c.append(.init(id: "clip.\(v.id).postToday", title: "Post today", symbol: "bolt", disabled: longWhy ?? (v.excluded ? "Excluded" : nil)) {
      [weak self] in self?.postToday(v.id)
    })
    let notPlanned = nextSlotByVideo[v.id] == nil ? "Not planned — order follows score; change the score to move it" : nil
    c.append(.init(id: "clip.\(v.id).moveUp", title: "Move up", symbol: "arrow.up",
                   disabled: longWhy ?? notPlanned ?? (neighbourSlot(v.id, -1) == nil ? "Already first" : nil)) { [weak self] in self?.moveVideo(v.id, by: -1) })
    c.append(.init(id: "clip.\(v.id).moveDown", title: "Move down", symbol: "arrow.down",
                   disabled: longWhy ?? notPlanned ?? (neighbourSlot(v.id, 1) == nil ? "Already last" : nil)) { [weak self] in self?.moveVideo(v.id, by: 1) })
    c.append(.init(id: "clip.\(v.id).skipNext", title: "Skip next slot", symbol: "forward.end", disabled: longWhy ?? notPlanned) {
      [weak self] in self?.skipNext(v.id)
    })
    if short {
      let back = stageBlocker(v, .back), fwd = stageBlocker(v, .forward)
      c.append(.init(id: "clip.\(v.id).stageBack", title: "\(stageBackTitle(v)) (back a stage)", symbol: "chevron.left",
                     subtitle: back == nil ? stageBackHelp(v) : nil, disabled: back) { [weak self] in self?.stageBack([v.id]) })
      c.append(.init(id: "clip.\(v.id).stageForward", title: "\(stageForwardTitle(v)) (forward a stage)", symbol: "chevron.right",
                     subtitle: fwd == nil ? stageForwardHelp(v) : nil, disabled: fwd) { [weak self] in self?.stageForward([v.id]) })
    }
    c.append(.init(id: "clip.\(v.id).exclude", title: v.excluded ? "Include" : "Exclude", symbol: v.excluded ? "plus.circle" : "minus.circle") {
      [weak self] in self?.setExcluded([v.id], !v.excluded)
    })
    if short {
      c.append(.init(id: "clip.\(v.id).agentPrompt", title: "Copy agent prompt", symbol: "text.bubble") { [weak self] in self?.copyAgentPrompt([v.id]) })
      for k in Kind.allCases where k != v.kind {
        c.append(.init(id: "clip.\(v.id).kind.\(k.rawValue)", title: "Set kind: \(k.displayName)", symbol: "tag") { [weak self] in self?.setKind([v.id], k) })
      }
      c.append(.init(id: "clip.\(v.id).rerender", title: "Re-render", symbol: "arrow.triangle.2.circlepath",
                     disabled: missing ? "File missing" : nil) { [weak self] in self?.reRender(v.id) })
      c.append(.init(id: "clip.\(v.id).duplicateVersion", title: "Duplicate latest version", symbol: "plus.square.on.square") { [weak self] in
        self?.duplicateVersion(v.id)
      })
      for p in settings.activePlatforms where repostBlocker(v.id, p) == nil {
        c.append(.init(id: "clip.\(v.id).repost.\(p.rawValue)", title: "Repost on \(p.displayName)", symbol: "arrow.uturn.forward") { [weak self] in
          self?.repost(v.id, p)
        })
      }
    } else if v.longformURL == nil {
      c.append(.init(id: "clip.\(v.id).longform", title: "Mark long-form posted…", symbol: "checkmark.circle") { [weak self] in
        self?.screen = .library
        BrowseUI.shared.longformTargets = [v]
      })
    }
    return c.map { cmd in
      var cmd = cmd
      cmd.group = name
      return cmd
    }
  }

  /// A recent command id back to its command (clip rows and clip actions included).
  func paletteCommand(id: String) -> PaletteCommand? {
    if let c = (paletteActions + paletteGoTo).first(where: { $0.id == id }) { return c }
    guard id.hasPrefix("clip.") else { return nil }
    let rest = id.dropFirst(5)
    if let v = video(String(rest)) { return paletteClipRow(v) }
    guard let vid = videos.first(where: { rest.hasPrefix($0.id + ".") }) else { return nil }
    return paletteClipCommands(vid).first { $0.id == id }.map { cmd in
      var cmd = cmd
      cmd = PaletteCommand(id: cmd.id, title: "\(cmd.title) · \(displayName(vid))", symbol: cmd.symbol, hint: cmd.hint, group: "Recents",
                           subtitle: nil, disabled: cmd.disabled, keepsOpen: cmd.keepsOpen, run: cmd.run)
      return cmd
    }
  }
}

// MARK: - Palette

/// ⌘K (DESIGN-v2 §3, ref APP.CMD Magnific): a 640 pt e2 surface with a capsule search field, Recents and Actions,
/// shortcuts right-aligned in caption tertiary. Typing searches commands and clips (by display name); a clip opens
/// its own action page (score, pin, move, exclude, open editor, agent prompt…). ↑/↓ move, ↩ runs, Esc goes back /
/// closes, ⌫ on an empty field leaves a clip page.
struct CommandPalette: View {
  @Bindable var model: AppModel
  @Bindable private var ui = BrowseUI.shared
  @State private var index = 0
  @FocusState private var focused: Bool

  private var clip: Video? { ui.paletteClipId.flatMap(model.video) }

  private var sections: [(String, [PaletteCommand])] {
    let q = ui.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
    func match(_ c: PaletteCommand) -> Bool { q.isEmpty || c.title.lowercased().contains(q) }
    if let v = clip {
      let cmds = model.paletteClipCommands(v).filter(match)
      return [(model.displayName(v), cmds)]
    }
    if q.isEmpty {
      var out: [(String, [PaletteCommand])] = []
      let recents = model.recentCommands.compactMap(model.paletteCommand(id:))
      if !recents.isEmpty { out.append(("Recents", recents)) }
      out.append(("Actions", model.paletteActions))
      out.append(("Go to", model.paletteGoTo))
      return out
    }
    var out: [(String, [PaletteCommand])] = []
    let clips = model.paletteClips(matching: q).map { model.paletteClipRow($0) }
    if !clips.isEmpty { out.append(("Clips", clips)) }
    let actions = model.paletteActions.filter(match)
    if !actions.isEmpty { out.append(("Actions", actions)) }
    let go = model.paletteGoTo.filter(match)
    if !go.isEmpty { out.append(("Go to", go)) }
    return out
  }

  var body: some View {
    let secs = sections
    let flat = secs.flatMap(\.1)
    ZStack(alignment: .top) {
      DS.color.scrim.ignoresSafeArea().contentShape(Rectangle()).onTapGesture { close() }
      VStack(spacing: 0) {
        searchRow(flat)
          .padding(DS.space.sm)
        DSSeparator()
        list(secs, flat: flat)
        DSSeparator()
        HStack(spacing: DS.space.md) {
          footer("↑ ↓", "Navigate")
          footer("↩", "Select")
          footer("esc", clip == nil ? "Close" : "Back")
          Spacer()
          if clip == nil { Text("Type a clip name to act on it").font(DS.type.caption).foregroundStyle(DS.color.textTertiary) }
        }
        .padding(.horizontal, DS.space.md)
        .frame(height: 36)
      }
      .frame(width: 640)
      .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e2)
      .padding(.top, 88)
    }
    .onAppear {
      focused = true
      index = 0
    }
    .onChange(of: ui.paletteQuery) { index = 0 }
    .onChange(of: ui.paletteClipId) { index = 0 }
  }

  // MARK: Pieces

  private func searchRow(_ flat: [PaletteCommand]) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(DS.color.textTertiary)
      if let v = clip {
        Button {
          ui.paletteClipId = nil
        } label: {
          HStack(spacing: 4) {
            Text(model.displayName(v)).lineLimit(1)
            Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.color.textTertiary)
          }
          .font(DS.type.captionMedium)
          .foregroundStyle(DS.color.text)
          .padding(.horizontal, 10)
          .frame(height: 24)
          .background(DS.color.selected, in: Capsule())
          .frame(maxWidth: 220)
          .fixedSize()
        }
        .buttonStyle(.plain)
        .dsTooltip("Back to all commands")
      }
      TextField(clip == nil ? "Search clips and commands…" : "Filter actions…", text: $ui.paletteQuery)
        .textFieldStyle(.plain)
        .font(Font.system(size: 15))
        .foregroundStyle(DS.color.text)
        .focused($focused)
        .onSubmit { run(at: index, in: flat) }
        .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
        .onKeyPress(.downArrow) { index = min(max(0, flat.count - 1), index + 1); return .handled }
        .onKeyPress(.delete) {
          guard ui.paletteQuery.isEmpty, clip != nil else { return .ignored }
          ui.paletteClipId = nil
          return .handled
        }
        .onExitCommand { back() }
      Text("⌘K").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    }
    .padding(.horizontal, 14)
    .frame(height: DS.size.controlLg)
    .modifier(DSFieldBox(focused: false, hovering: false, error: false, disabled: false, radius: DS.size.controlLg / 2))
  }

  private func list(_ secs: [(String, [PaletteCommand])], flat: [PaletteCommand]) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          let ids = flat.map(\.id)
          ForEach(Array(secs.enumerated()), id: \.offset) { si, section in
            Text(section.0).font(DS.type.micro).foregroundStyle(DS.color.textTertiary).lineLimit(1)
              .padding(.horizontal, 10).padding(.top, si == 0 ? 6 : 12).padding(.bottom, 4)
            ForEach(Array(section.1.enumerated()), id: \.offset) { _, cmd in
              let i = ids.firstIndex(of: cmd.id) ?? -1
              PaletteRow(command: cmd, selected: i == index)
                .id("\(si).\(cmd.id)")
                .onTapGesture { run(cmd) }
                .onHover { if $0, i >= 0 { index = i } }
            }
          }
          if flat.isEmpty {
            VStack(spacing: 4) {
              Text(clip == nil ? "No clip or command matches “\(ui.paletteQuery)”" : "No action matches “\(ui.paletteQuery)”")
                .font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
              Text("Try part of a title or a raw tag").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.space.xxl)
          }
        }
        .padding(6)
      }
      .frame(maxHeight: 420)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: index) { _, i in
        guard flat.indices.contains(i), let s = secs.firstIndex(where: { $0.1.contains { $0.id == flat[i].id } }) else { return }
        proxy.scrollTo("\(s).\(flat[i].id)")
      }
    }
  }

  private func footer(_ k: String, _ t: String) -> some View {
    HStack(spacing: 5) {
      Text(k).font(DS.type.captionMedium).foregroundStyle(DS.color.textSecondary)
      Text(t).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    }
  }

  // MARK: Actions

  private func run(at i: Int, in flat: [PaletteCommand]) {
    guard flat.indices.contains(i) else { return }
    run(flat[i])
  }

  private func run(_ c: PaletteCommand) {
    if let why = c.disabled { model.show(why, error: true); return }
    model.noteCommand(c.id)
    if c.keepsOpen {
      c.run()
      focused = true
      return
    }
    close()
    c.run()
  }

  private func back() {
    if clip != nil { ui.paletteClipId = nil; ui.paletteQuery = "" } else { close() }
  }

  private func close() {
    model.showPalette = false
    ui.paletteQuery = ""
    ui.paletteClipId = nil
  }
}

/// A palette row: icon tile · title (+ subtitle / disabled reason) · right-aligned shortcut (caption tertiary).
private struct PaletteRow: View {
  let command: PaletteCommand
  let selected: Bool

  var body: some View {
    let enabled = command.disabled == nil
    HStack(spacing: 10) {
      Image(systemName: command.symbol)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(enabled ? DS.color.text : DS.color.textTertiary)
        .frame(width: 26, height: 26)
        .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        Text(command.title).font(DS.type.callout).foregroundStyle(enabled ? DS.color.text : DS.color.textTertiary).lineLimit(1)
        if let s = command.disabled ?? command.subtitle {
          Text(s).font(DS.type.caption).foregroundStyle(DS.color.textTertiary).lineLimit(1)
        }
      }
      Spacer(minLength: DS.space.sm)
      if let h = command.hint {
        Text(h).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      } else if selected && enabled {
        Image(systemName: "return").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.color.textTertiary)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: command.subtitle != nil || command.disabled != nil ? 44 : 36)
    .background(selected ? DS.color.selected : .clear, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .contentShape(Rectangle())
    .dsTooltip(command.disabled)
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
      StageMenuItems(model: model, video: video, targets: targets)
      Divider()
      Button("Duplicate version", systemImage: "plus.square.on.square") { model.duplicateVersion(video.id) }
      Button("Re-render", systemImage: "arrow.triangle.2.circlepath") { model.reRender(video.id) }
    } else {
      Button("Add \(targets.count) to week", systemImage: "calendar.badge.plus") { model.addToWeek(targets) }
      StageMenuItems(model: model, video: video, targets: targets)
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
        .disabled(model.heldReason(post.videoId) != nil).help(model.heldReason(post.videoId) ?? "Due now on today's slot")
      Button("Shift plan", systemImage: "calendar.badge.clock") { model.shiftPlan(post) }
        .disabled(model.heldReason(post.videoId) != nil).help(model.heldReason(post.videoId) ?? "Next free slot")
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


/// ⌘K "Set score…": one big number field (DSDialog in a sheet).
struct ScorePromptSheet: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var text = ""
  @Environment(\.dismiss) private var dismiss

  private var value: Int? { Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (0...100).contains($0) ? $0 : nil } }

  var body: some View {
    DSDialog("Score “\(model.displayName(video))”", description: "0 to 100. Higher scores post sooner.", icon: "number", width: 400,
             onClose: { dismiss() }) {
      DSTextField(placeholder: "0–100", text: $text, error: !text.isEmpty && value == nil ? "Type a whole number from 0 to 100" : nil,
                  size: .lg, onSubmit: save)
    } footer: {
      DSButton("Cancel", variant: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
      DSButton("Save", variant: .primary, disabledReason: value == nil ? "Type a score from 0 to 100" : nil, action: save)
        .keyboardShortcut(.defaultAction)
    }
    .background(DS.color.surfaceRaised)
    .onAppear { text = video.score.map(String.init) ?? "" }
  }

  private func save() {
    guard let n = value else { return }
    model.setScore([video.id], n)
    dismiss()
  }
}

/// ⌘K "Pin to date…" (DSDialog in a sheet).
struct PinPromptSheet: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var date = Date()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    DSDialog("Pin “\(model.displayName(video))”", description: "It posts on this day; the rest of the plan flows around it.",
             icon: "pin", width: 360, onClose: { dismiss() }) {
      DatePicker("Date", selection: $date, in: model.now..., displayedComponents: .date)
        .datePickerStyle(.graphical).labelsHidden()
        .frame(maxWidth: .infinity)
    } footer: {
      DSButton("Cancel", variant: .ghost) { dismiss() }.keyboardShortcut(.cancelAction)
      DSButton("Pin", variant: .primary) {
        model.pin(video.id, date: date)
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .background(DS.color.surfaceRaised)
    .onAppear { date = max(model.now, date) }
  }
}
