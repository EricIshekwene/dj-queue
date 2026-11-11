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
  /// Remembered in Recents when run.
  var isRecent = true
  /// Character offsets of the search match, shown bold.
  var titleMatches: [Range<Int>] = []
  var subtitleMatches: [Range<Int>] = []
  let run: () -> Void
}

// MARK: - Commands

extension AppModel {
  /// Destinations: every screen (⌘1…⌘7) and Settings.
  var paletteGoTo: [PaletteCommand] {
    Screen.allCases.map { s in
      PaletteCommand(id: "go.\(s.rawValue)", title: "Go to \(s.title)", symbol: s.symbol, hint: "⌘\(s.key.character)", group: "Go to") {
        [weak self] in self?.leaveForScreen(s)
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
      c.append(.init(id: "selection.unqueue", title: "Send \(queued.count) back to Edit", symbol: "arrow.uturn.backward",
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
                     symbol: "text.bubble", subtitle: "Ask your agent for song-name titles") { [weak self] in self?.copyAgentPrompt(shorts) })
    }
    c.append(.init(id: "post.pauseAll", title: settings.paused ? "Resume all posting" : "Pause all posting…",
                   symbol: settings.paused ? "play.circle" : "pause.circle",
                   subtitle: settings.paused ? "Hand posts to you again from now (undoable)" : "Asks first") { [weak self] in
      guard let self else { return }
      if self.settings.paused { self.setPaused(false) } else { self.confirmPause = true }
    })
    if !problems.isEmpty {
      c.append(.init(id: "post.review", title: "Review \(problems.count) problem\(problems.count == 1 ? "" : "s")", symbol: "exclamationmark.octagon") {
        [weak self] in self?.reviewProblems()
      })
    }

    // Round 21: the same picker as Edit's "Add photos" button.
    c.append(.init(id: "photos.add", title: "Add photos…", symbol: "photo.badge.plus",
                   subtitle: "Pick one photo or several for a carousel. They land in Edit") { [weak self] in self?.askAddPhotos() })
    c.append(.init(id: "calendar.open", title: "Open Calendar", symbol: "calendar", subtitle: "See today, the week or the month going out") { [weak self] in
      self?.editor = nil
      self?.screen = .calendar
    })
    for m in CalendarViewMode.allCases {
      c.append(.init(id: "calendar.\(m.rawValue)", title: "Calendar: \(m.title)", symbol: "calendar", hint: m.key) { [weak self] in
        self?.editor = nil
        self?.setCalendarMode(m)
        self?.screen = .calendar
      })
    }

    for p in settings.activePlatforms {
      let paused = settings.pausedPlatforms.contains(p)
      c.append(.init(id: "post.pause.\(p.rawValue)", title: paused ? "Resume \(p.displayName)" : "Pause \(p.displayName)",
                     symbol: paused ? "play" : "pause",
                     subtitle: paused ? "Hand out its posts again" : "Stop its posts; other platforms keep going") { [weak self] in
        self?.setPlatformPaused(p, !paused)
      })
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
                     subtitle: "Put this post back to planned",
                     disabled: canReset(post) ? nil : heldReason(post.videoId) ?? "Its time has passed or it's still planned") { [weak self] in self?.reset(post) })
      c.append(.init(id: "post.skip", title: "Skip post (\(n))", symbol: "forward",
                     disabled: canSkip(post) ? nil : "Already \(post.state.displayName.lowercased())") { [weak self] in self?.skip(post) })
      if post.state == .overdue {
        let held = heldReason(post.videoId)
        c.append(.init(id: "post.postNow", title: "Post now (\(n))", symbol: "bolt", subtitle: "Make it due now and open the Calendar",
                       disabled: held) { [weak self] in self?.postNow(post) })
        c.append(.init(id: "post.shiftPlan", title: "Shift plan (\(n))", symbol: "calendar.badge.clock",
                       subtitle: "Move it to the next free slot", disabled: held) { [weak self] in
          self?.shiftPlan(post)
        })
      }
    }

    c.append(.init(id: "health.tick", title: "Run engine tick now", symbol: "bolt.horizontal.circle",
                   subtitle: "Check and prepare due posts now") { [weak self] in self?.runTick() })
    c.append(.init(id: "health.doctor", title: "Open Doctor", symbol: "stethoscope", subtitle: "Check the app for problems") { [weak self] in
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
    // A photo post says "Photo" / "Carousel · 5" where a clip names its night (D18).
    let meta = [clipContext(v), v.type == .long ? "Long-form" : v.score.map { "Score \($0)" }, chip].compactMap { $0 }.filter { !$0.isEmpty }
    let symbol = v.isPhoto ? (v.isCarousel ? "photo.stack" : "photo") : v.type == .long ? "rectangle" : "rectangle.portrait"
    return PaletteCommand(id: "clip.\(v.id)", title: title ?? displayName(v), symbol: symbol,
                          hint: "Actions ›", group: "Clips", subtitle: meta.joined(separator: " · "), keepsOpen: true) {
      let ui = BrowseUI.shared
      ui.paletteReturnQuery = ui.paletteQuery
      ui.paletteClipId = v.id
      ui.paletteQuery = ""
    }
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
    c.append(.init(id: "clip.\(v.id).preview", title: "Quick look", symbol: "eye",
                   disabled: missing ? "File missing" : nil) { [weak self] in self?.previewVideo = v })
    c.append(.init(id: "clip.\(v.id).score", title: v.score == nil ? "Set score…" : "Change score (\(v.score!))…", symbol: "number",
                   subtitle: v.isPhoto && v.score == nil ? "Optional for a photo: without one it takes the next open day" : nil,
                   disabled: longWhy) { [weak self] in self?.scorePrompt = v })
    c.append(.init(id: "clip.\(v.id).pinDate", title: "Pin to date…", symbol: "calendar", disabled: longWhy ?? (v.excluded ? "Excluded" : nil)) {
      [weak self] in self?.pinPrompt = v
    })
    c.append(.init(id: "clip.\(v.id).pinTomorrow", title: "Pin to tomorrow", symbol: "pin", disabled: longWhy ?? (v.excluded ? "Excluded" : nil)) {
      [weak self] in
      guard let self else { return }
      self.pin(v.id, dayKey: self.dm.addDays(self.todayKey, 1))
    })
    c.append(.init(id: "clip.\(v.id).postToday", title: "Post today", symbol: "bolt", subtitle: "The rest of the Calendar moves a day later",
                   disabled: longWhy ?? (v.excluded ? "Excluded" : nil)) {
      [weak self] in self?.postTodayAsking([v.id])
    })
    let notPlanned = nextSlotByVideo[v.id] == nil ? "Not planned — order follows score; change the score to move it" : nil
    c.append(.init(id: "clip.\(v.id).moveUp", title: "Move up", symbol: "arrow.up", subtitle: "Swap days with the clip before it",
                   disabled: longWhy ?? notPlanned ?? (neighbourSlot(v.id, -1) == nil ? "Already first" : nil)) { [weak self] in self?.moveVideo(v.id, by: -1) })
    c.append(.init(id: "clip.\(v.id).moveDown", title: "Move down", symbol: "arrow.down", subtitle: "Swap days with the clip after it",
                   disabled: longWhy ?? notPlanned ?? (neighbourSlot(v.id, 1) == nil ? "Already last" : nil)) { [weak self] in self?.moveVideo(v.id, by: 1) })
    c.append(.init(id: "clip.\(v.id).skipNext", title: "Move one slot later", symbol: "forward.end",
                   subtitle: "Swap with the next open slot", disabled: longWhy ?? notPlanned) {
      [weak self] in self?.skipNext(v.id)
    })
    if short {
      let back = stageBlocker(v, .back), fwd = stageBlocker(v, .forward)
      c.append(.init(id: "clip.\(v.id).stageBack", title: "\(stageBackTitle(v)) (back a stage)", symbol: "chevron.left",
                     subtitle: back == nil ? stageBackHelp(v) : nil, disabled: back) { [weak self] in self?.stageBack([v.id]) })
      c.append(.init(id: "clip.\(v.id).stageForward", title: "\(stageForwardTitle(v)) (forward a stage)", symbol: "chevron.right",
                     subtitle: fwd == nil ? stageForwardHelp(v) : nil, disabled: fwd) { [weak self] in self?.stageForward([v.id]) })
      // Round 21: an exact day and minute, outside the regular schedule.
      let timeWhy = postAtBlocker(v)
      c.append(.init(id: "clip.\(v.id).postAt", title: postAtMenuTitle([v.id]), symbol: "clock",
                     subtitle: timeWhy == nil ? postAtHelp(v) : nil, disabled: timeWhy) { [weak self] in self?.askPostAt([v.id]) })
      if setTime(v.id) != nil {
        c.append(.init(id: "clip.\(v.id).regularSchedule", title: StageWording.useRegularSchedule, symbol: "arrow.uturn.backward",
                       subtitle: "Take the set time off") { [weak self] in self?.clearSetTimeAsking([v.id]) })
      }
    }
    c.append(.init(id: "clip.\(v.id).exclude", title: v.excluded ? "Include" : "Exclude", symbol: v.excluded ? "plus.circle" : "minus.circle",
                   subtitle: v.excluded ? "Let this clip be scheduled again" : "Never post this clip") {
      [weak self] in self?.setExcluded([v.id], !v.excluded)
    })
    if short {
      // Round 21: a photo post has no song to look up, no kind, and one version this round (D16): no repost.
      let photo = v.isPhoto
      if !photo {
        c.append(.init(id: "clip.\(v.id).agentPrompt", title: "Copy agent prompt", symbol: "text.bubble",
                       subtitle: "Ask your agent for a title") { [weak self] in self?.copyAgentPrompt([v.id]) })
        for k in Kind.allCases where k != v.kind {
          c.append(.init(id: "clip.\(v.id).kind.\(k.rawValue)", title: "Set kind: \(k.displayName)", symbol: "tag") { [weak self] in self?.setKind([v.id], k) })
        }
      }
      c.append(.init(id: "clip.\(v.id).rerender", title: "Re-render", symbol: "arrow.triangle.2.circlepath",
                     subtitle: photo ? "Make the post photos again on the next tick" : "Make the post video again on the next tick",
                     disabled: missing ? "File missing" : nil) { [weak self] in self?.forceReRender([v.id]) })
      if !photo {
        c.append(.init(id: "clip.\(v.id).duplicateVersion", title: "Duplicate latest version", symbol: "plus.square.on.square",
                     subtitle: "Copy its edits into a new version (for reposts)") { [weak self] in
          self?.duplicateVersion(v.id)
        })
      }
      for p in settings.activePlatforms where !photo && repostBlocker(v.id, p) == nil {
        c.append(.init(id: "clip.\(v.id).repost.\(p.rawValue)", title: "Repost on \(p.displayName)", symbol: "arrow.uturn.forward",
                       subtitle: "Plan a new \(p.displayName) post of the latest version") { [weak self] in
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

  /// A recent command id back to its command (clip rows, clip actions and search results included). nil when what it
  /// pointed at is gone: the row just leaves Recents.
  func paletteCommand(id: String) -> PaletteCommand? {
    if let c = (paletteActions + paletteGoTo).first(where: { $0.id == id }) { return c }
    if id.hasPrefix("search.") { return searchCommand(id: id).map { c in
      var c = c
      c.group = "Recents"
      return c
    } }
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

// MARK: - Clip actions shared by ⌘K and the context menus

extension AppModel {
  /// Re-render (⌘K, right-click): the same forced fresh render as the bulk bars' Re-render (BulkActions.reRender —
  /// current renders retired, the engine makes them again on its next tick). One clip applies at once with Undo;
  /// several ask first.
  func forceReRender(_ ids: [String]) {
    let n = AppModel.pipelineClips(ids.count)
    pipelineBulk("Re-render \(n)?", verb: "Re-render", ids: ids, changes: [.init(field: "Renders", value: "Made again on the next engine tick")],
                 done: "Re-render queued for \(n)") { b, dry in try b.reRender(ids, dryRun: dry) }
  }

  /// Context-menu Kind / Score / Exclude for one or many clips: one batch, asks first for several, Undo either way.
  func menuSetKind(_ ids: [String], _ k: Kind) {
    let n = AppModel.pipelineClips(ids.count)
    pipelineBulk("Set \(n) to \(k.displayName)?", verb: "Set kind", ids: ids, changes: [.init(field: "Kind", value: k.displayName)],
                 done: "Kind set to \(k.displayName)") { b, dry in try b.setKind(ids, k, dryRun: dry) }
  }

  func menuSetScore(_ ids: [String], _ score: Int?) {
    let n = AppModel.pipelineClips(ids.count)
    pipelineBulk(score.map { "Score \(n) \($0)?" } ?? "Clear the score of \(n)?", verb: score == nil ? "Clear score" : "Set score", ids: ids,
                 // A photo keeps its place without a score (round 21, D4); a clip goes back to Score.
                 changes: [.init(field: "Score", value: score.map(String.init)
                                   ?? (ids.contains { video($0)?.isPhoto != true } ? "None · back to Score" : "None"))],
                 done: score.map { "Score \($0)" } ?? "Score cleared") { b, dry in try b.setScore(ids, score, dryRun: dry) }
  }

  func menuSetExcluded(_ ids: [String], _ ex: Bool) {
    let n = AppModel.pipelineClips(ids.count)
    pipelineBulk("\(ex ? "Exclude" : "Include") \(n)?", verb: ex ? "Exclude" : "Include", ids: ids,
                 changes: [.init(field: "Posting", value: ex ? "Excluded · never posts" : "Included · can be planned again")],
                 done: ex ? "Excluded" : "Included") { b, dry in try b.setExcluded(ids, ex, dryRun: dry) }
  }
}

// MARK: - Palette

/// ⌘K (DESIGN-v2 §3, ref APP.CMD Magnific): a 640 pt e2 surface with a capsule search field. Empty field: Recents,
/// Actions and Go to. Typing searches the whole app (`SearchSources.swift`): type chips under the field (Tab cycles
/// them), result groups capped at five with a "Show all" row, the match in bold and, for a hit that isn't in the title,
/// where it matched. A clip opens its own action page (score, pin, move, exclude, open editor, agent prompt…). ↑/↓
/// move, ↩ runs, Esc goes back / closes, ⌫ on an empty field leaves a clip page.
struct CommandPalette: View {
  @Bindable var model: AppModel
  @Bindable private var ui = BrowseUI.shared
  @State private var index = 0
  @State private var memo = PaletteMemo()
  @FocusState private var focused: Bool

  private var clip: Video? { ui.paletteClipId.flatMap(model.video) }

  private var content: PaletteContent {
    if let v = clip {
      let q = ui.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
      var out = PaletteContent()
      out.add(model.displayName(v), model.paletteClipCommands(v).filter { q.isEmpty || $0.title.lowercased().contains(q) })
      return out
    }
    return memo.content(model, text: ui.paletteQuery, scope: ui.paletteScope)
  }

  /// The chips on offer, in order. Tab walks these.
  private func chips(_ c: PaletteContent) -> [SearchScope] {
    SearchScope.allCases.filter { c.counts[$0] != nil }
  }

  var body: some View {
    let c = content
    ZStack(alignment: .top) {
      DS.color.scrim.ignoresSafeArea().contentShape(Rectangle()).onTapGesture { close() }
      VStack(spacing: 0) {
        searchRow
          .padding(DS.space.sm)
        if clip == nil, chips(c).count > 1 { chipRow(c) }
        DSSeparator()
        list(c)
        DSSeparator()
        HStack(spacing: DS.space.md) {
          footer("↑ ↓", "Navigate")
          footer("↩", "Select")
          if clip == nil, chips(c).count > 1 { footer("tab", "Filter") }
          footer("esc", clip == nil ? "Close" : "Back")
          Spacer()
          if clip == nil {
            Text(c.note ?? (c.isSearch ? "" : "Clips, posts, weeks, settings and actions")).font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
          }
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
      // A chip belongs to one search; text handed over by "Search everywhere" stays.
      ui.paletteScope = .all
    }
    .onChange(of: ui.paletteQuery) {
      index = 0
      // A chip that lost its hits really goes back to All: deleting a letter doesn't jump to it again.
      if clip == nil, ui.paletteScope != content.scope { ui.paletteScope = content.scope }
    }
    .onChange(of: ui.paletteClipId) { index = 0 }
    .onChange(of: ui.paletteScope) { index = 0 }
  }

  // MARK: Pieces

  private var searchRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(DS.color.textTertiary)
      if let v = clip {
        Button {
          back()
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
        .dsTooltip("Back to all commands", shortcut: "esc")
      }
      TextField(clip == nil ? "Search everything…" : "Filter actions…", text: $ui.paletteQuery)
        .textFieldStyle(.plain)
        .font(Font.system(size: 15))
        .foregroundStyle(DS.color.text)
        .focused($focused)
        // These read `content`, not a list from the render: AppKit's field can keep an older closure after a chip
        // change, and ↩ would run a row that's no longer listed.
        .onSubmit { run(at: index, in: content.flat) }
        .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
        .onKeyPress(.downArrow) { index = min(max(0, content.flat.count - 1), index + 1); return .handled }
        .onKeyPress(.delete) {
          guard ui.paletteQuery.isEmpty, clip != nil else { return .ignored }
          back()
          return .handled
        }
        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
          // Handled either way: Tab never moves focus out of the field.
          let now = content
          let on = chips(now)
          guard clip == nil, on.count > 1 else { return .handled }
          let at = on.firstIndex(of: now.scope) ?? 0
          let backward = press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")
          ui.paletteScope = on[(at + (backward ? on.count - 1 : 1)) % on.count]
          return .handled
        }
        .onExitCommand { back() }
      Text("⌘K").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    }
    .padding(.horizontal, 14)
    .frame(height: DS.size.controlLg)
    .modifier(DSFieldBox(focused: false, hovering: false, error: false, disabled: false, radius: DS.size.controlLg / 2))
  }

  /// Type chips: only kinds with hits, each with its count.
  private func chipRow(_ c: PaletteContent) -> some View {
    let scopes = chips(c).filter { $0 != .all }
    let options = scopes.map { s in
      DSStatusChipOption(id: s.rawValue, title: s.title, count: c.counts[s], tooltip: "Show only \(s.title.lowercased())")
    }
    return HStack(spacing: 6) {
      DSStatusChips(options: options, selection: Binding(
        get: { c.scope == .all ? nil : c.scope.rawValue },
        set: { ui.paletteScope = $0.flatMap(SearchScope.init(rawValue:)) ?? .all
          focused = true }),
                    allCount: c.counts[.all], allTooltip: "Show every kind of result", size: .sm)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DS.space.sm)
    .padding(.bottom, DS.space.xs)
  }

  private func list(_ c: PaletteContent) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(Array(c.sections.enumerated()), id: \.offset) { si, section in
            Text(section.title).font(DS.type.micro).foregroundStyle(DS.color.textTertiary).lineLimit(1)
              .padding(.horizontal, 10).padding(.top, si == 0 ? 6 : 12).padding(.bottom, 4)
            ForEach(section.rows) { row in
              PaletteRow(command: row.command, selected: row.index == index)
                .id(row.index)
                .onTapGesture { run(row.command) }
                .onHover { if $0 { index = row.index } }
            }
          }
          if c.flat.isEmpty {
            VStack(spacing: 4) {
              Text(clip == nil ? "Nothing matches “\(ui.paletteQuery)”" : "No action matches “\(ui.paletteQuery)”")
                .font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
              if clip == nil {
                Text("Try part of a title, a caption, a date or a setting").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
              }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.space.xxl)
          }
        }
        .padding(6)
      }
      .frame(maxHeight: 420)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: index) { _, i in proxy.scrollTo(i) }
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
    if c.isRecent { model.noteCommand(c.id) }
    if c.keepsOpen {
      c.run()
      focused = true
      return
    }
    close()
    let (screen, editor) = (model.screen, model.editor)
    c.run()
    // Anything that went to another screen or opened a clip leaves what was covering it, however the action got there.
    if model.screen != screen {
      if model.editor == editor { model.editor = nil }
      model.showSettings = false
    } else if model.editor != editor {
      model.showSettings = false
    }
  }

  private func back() {
    if clip != nil {
      ui.paletteClipId = nil
      ui.paletteQuery = ui.paletteReturnQuery
      ui.paletteReturnQuery = ""
      focused = true
    } else {
      close()
    }
  }

  private func close() { model.closePalette() }
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
        PaletteMatchText(text: command.title, matches: command.titleMatches, font: DS.type.callout, strong: DS.type.calloutSemibold)
          .foregroundStyle(enabled ? DS.color.text : DS.color.textTertiary).lineLimit(1)
        if let s = command.disabled ?? command.subtitle {
          PaletteMatchText(text: s, matches: command.disabled == nil ? command.subtitleMatches : [], font: DS.type.caption,
                           strong: DS.type.captionSemibold)
            .foregroundStyle(DS.color.textTertiary).lineLimit(1)
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

/// Text with the matched characters in a stronger weight.
private struct PaletteMatchText: View {
  let text: String
  let matches: [Range<Int>]
  let font: Font
  let strong: Font

  var body: some View {
    if matches.isEmpty {
      Text(text).font(font)
    } else {
      Text(attributed)
    }
  }

  private var attributed: AttributedString {
    let chars = Array(text)
    var out = AttributedString()
    func add(_ a: Int, _ b: Int, _ f: Font) {
      guard a < b else { return }
      var piece = AttributedString(String(chars[a..<b]))
      piece.font = f
      out += piece
    }
    var at = 0
    for r in matches where r.lowerBound >= at && r.upperBound <= chars.count {
      add(at, r.lowerBound, font)
      add(r.lowerBound, r.upperBound, strong)
      at = r.upperBound
    }
    add(at, chars.count, font)
    return out
  }
}

// MARK: - APP.CTX shared context menus

struct VideoContextMenu: View {
  @Bindable var model: AppModel
  let video: Video
  var ids: [String] = []

  var body: some View {
    let targets = ids.count > 1 && ids.contains(video.id) ? ids : [video.id]
    let many = targets.count > 1
    let n = many ? " \(targets.count)" : ""
    if !many {
      Button("Open editor", systemImage: "slider.horizontal.below.rectangle") { model.openEditor(video.id, in: model.selectedVideoIds) }
      Button("Preview", systemImage: "play.rectangle") { model.previewVideo = video }
      Divider()
      Button("Post today", systemImage: "bolt") { model.postTodayAsking([video.id]) }
      Button("Pin to tomorrow", systemImage: "pin") { model.pin(video.id, dayKey: model.dm.addDays(model.todayKey, 1)) }
      Button("Move one slot later", systemImage: "forward.end") { model.skipNext(video.id) }
      // Round 21 (D16): a photo post has one version this round, so nothing to repost or duplicate.
      if !video.isPhoto { RepostMenu(model: model, videoId: video.id) }
      Divider()
      StageMenuItems(model: model, video: video, targets: targets)
      Divider()
      if !video.isPhoto { Button("Duplicate version", systemImage: "plus.square.on.square") { model.duplicateVersion(video.id) } }
      Button(model.libraryIsMissing(video) ? "Re-render — file missing" : "Re-render", systemImage: "arrow.triangle.2.circlepath") {
        model.forceReRender([video.id])
      }
      .disabled(model.libraryIsMissing(video))
    } else {
      StageMenuItems(model: model, video: video, targets: targets)
    }
    // A photo post has no kind (DJ vid or Talking is about a clip).
    if targets.contains(where: { model.video($0)?.isPhoto != true }) {
      Menu(many ? "Kind (\(targets.count))" : "Kind") {
        ForEach(Kind.allCases, id: \.self) { k in Button(k.displayName) { model.menuSetKind(targets, k) } }
      }
    }
    Menu(many ? "Score (\(targets.count))" : "Score") {
      ForEach([90, 80, 70, 60, 50, 40, 30], id: \.self) { s in Button("\(s)") { model.menuSetScore(targets, s) } }
      Button("Clear") { model.menuSetScore(targets, nil) }
    }
    Divider()
    Button(video.excluded ? "Include\(n)" : "Exclude\(n)", systemImage: video.excluded ? "plus.circle" : "minus.circle") {
      model.menuSetExcluded(targets, !video.excluded)
    }
  }
}

struct PostContextMenu: View {
  @Bindable var model: AppModel
  let post: PlatformPost

  var body: some View {
    if post.state == .posted, let u = post.url, let url = URL(string: u) {
      Button("Open live post", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
      Divider()
    }
    if model.postizState(post) == .draft {
      Button("Release Postiz draft…", systemImage: "paperplane") { model.releaseDraft(post) }
      Divider()
    }
    if !post.state.isTerminal {
      Button("Mark posted…", systemImage: "checkmark.circle") { model.markPostedTarget = post }
      Button("Copy caption", systemImage: "text.quote") { model.copyCaption(post) }
      if post.platform == .youtube { Button("Copy title", systemImage: "textformat") { model.copyTitle(post) } }
      Button("Open upload page", systemImage: "safari") { model.openUploadPage(post) }
      // Round 21: a photo post's render is one file per photo, and these give every one of them.
      let photos = model.video(post.videoId)?.photoCount ?? 0
      Button("Reveal in Finder", systemImage: "folder") { model.revealFiles(post) }
      Button(photos > 1 ? "Copy \(photos) photos" : "Copy file", systemImage: "doc.on.doc") { model.copyFiles(post) }
      Divider()
    }
    if !post.state.isTerminal || post.state == .posted {
      Button("Report problem…", systemImage: "exclamationmark.bubble") { model.reportTarget = post }
    }
    if post.state == .overdue {
      // Native menu items can't show a tooltip: the consequence (or why not) is in the title.
      let held = model.heldReason(post.videoId) != nil
      Button(held ? "Post now — sent back to Edit" : "Post now (due on today's slot)", systemImage: "bolt") { model.postNow(post) }
        .disabled(held)
      Button(held ? "Shift plan — sent back to Edit" : "Shift plan (to the next free slot)", systemImage: "calendar.badge.clock") {
        model.shiftPlan(post)
      }
      .disabled(held)
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
      DSButton("Cancel", variant: .ghost, shortcut: "esc") { dismiss() }.keyboardShortcut(.cancelAction)
      DSButton("Save", variant: .primary, disabledReason: value == nil ? "Type a score from 0 to 100" : nil,
               tooltip: "Save score; higher posts sooner", shortcut: "↩", action: save)
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
    DSDialog("Pin “\(model.displayName(video))”", description: "It posts on this day; the rest of the Calendar flows around it.",
             icon: "pin", width: 360, onClose: { dismiss() }) {
      DatePicker("Date", selection: $date, in: model.now..., displayedComponents: .date)
        .datePickerStyle(.graphical).labelsHidden()
        .frame(maxWidth: .infinity)
    } footer: {
      DSButton("Cancel", variant: .ghost, shortcut: "esc") { dismiss() }.keyboardShortcut(.cancelAction)
      DSButton("Pin", variant: .primary, tooltip: "Post it on this day; the rest flows around", shortcut: "↩") {
        model.pin(video.id, date: date)
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .background(DS.color.surfaceRaised)
    .onAppear { date = max(model.now, date) }
  }
}
