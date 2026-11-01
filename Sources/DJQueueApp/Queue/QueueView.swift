import DJQCore
import SwiftUI

/// Q.L: header (stat strip tabs + sort) · filter bar · ordered rows · right inspector.
struct QueueView: View {
  @Bindable var model: AppModel
  @State private var sessionFilter: String?
  @State private var kindFilter: Kind?
  @State private var scoreFilter: ClosedRange<Int>?
  @State private var search = ""

  var body: some View {
    VStack(spacing: 0) {
      QueueHeader(model: model)
      if model.queueSelection.count > 1 {
        BulkBar(model: model, ids: Array(model.queueSelection), onClear: { model.queueSelection = [] })
      } else {
        filterBar
      }
      Divider()
      content
    }
    .inspector(isPresented: $model.showInspector) {
      Group {
        if let id = model.queueSelection.first, model.queueSelection.count == 1, let v = model.video(id) {
          VideoInspector(model: model, video: v)
        } else {
          EmptyState(symbol: "sidebar.right", title: model.queueSelection.count > 1 ? "\(model.queueSelection.count) selected" : "No selection",
                     subtitle: model.queueSelection.count > 1 ? "Use the bar above to score, set kind or exclude." : "Select a video to see its details.")
        }
      }
      .inspectorColumnWidth(min: 280, ideal: DS.inspectorWidth, max: 380)
    }
  }

  // MARK: Rows

  private func filtered(_ vs: [Video]) -> [Video] {
    vs.filter { v in
      (sessionFilter == nil || v.sessionId == sessionFilter)
        && (kindFilter == nil || v.kind == kindFilter)
        && (scoreFilter == nil || (v.score.map { scoreFilter!.contains($0) } ?? false))
        && (search.isEmpty || v.tag.localizedCaseInsensitiveContains(search) || v.name.localizedCaseInsensitiveContains(search))
    }
  }

  /// Ready tab = upcoming planned slots (in date order) + the unplanned backlog (posting order).
  private var plannedRows: [(PlanSlot, Video)] {
    filtered(model.upcomingSlots.compactMap { model.video($0.videoId) }).isEmpty ? [] :
      model.upcomingSlots.compactMap { s in model.video(s.videoId).map { (s, $0) } }.filter { !filtered([$0.1]).isEmpty }
  }

  private var backlogRows: [Video] {
    let planned = Set(model.upcomingSlots.map(\.videoId))
    return filtered(model.ordered.filter { !planned.contains($0.id) })
  }

  private var tabRows: [Video] {
    switch model.queueTab {
    case .ready: []
    case .toScore: filtered(model.toScore)
    case .needsEdit: filtered(model.needsEdit)
    case .excluded: filtered(model.excluded)
    }
  }

  @ViewBuilder private var content: some View {
    let isEmpty = model.queueTab == .ready ? (plannedRows.isEmpty && backlogRows.isEmpty) : tabRows.isEmpty
    if model.videos.isEmpty {
      EmptyState(symbol: "film.stack", title: "No videos yet", subtitle: "Export clips from CapCut into a session's videos.json.",
                 buttonTitle: "Open Library") { model.screen = .library }
    } else if isEmpty {
      emptyForTab
    } else {
      list
    }
  }

  @ViewBuilder private var emptyForTab: some View {
    switch model.queueTab {
    case .ready:
      EmptyState(symbol: "tray", title: "Nothing ready", subtitle: "Score and edit videos to fill the queue.",
                 buttonTitle: model.toScore.isEmpty ? nil : "Score \(model.toScore.count) videos") { model.scoreMode = true }
    case .toScore: EmptyState(symbol: "checkmark.circle", title: "Everything is scored")
    case .needsEdit: EmptyState(symbol: "checkmark.circle", title: "Nothing needs edits")
    case .excluded: EmptyState(symbol: "minus.circle", title: "Nothing excluded")
    }
  }

  private var list: some View {
    List(selection: $model.queueSelection) {
      if model.queueTab == .ready {
        let planned = plannedRows
        if !planned.isEmpty {
          Section {
            ForEach(Array(planned.enumerated()), id: \.element.0.id) { i, pair in
              QueueRow(model: model, video: pair.1, position: i + 1, slot: pair.0)
                .tag(pair.1.id)
                .contextMenu { VideoContextMenu(model: model, video: pair.1, ids: Array(model.queueSelection)) }
            }
            .onMove { from, to in movePlanned(planned, from: from, to: to) }
          } header: {
            SectionHeader(title: "Planned", count: planned.count, note: "Drag to swap days")
          }
        }
        let backlog = backlogRows
        if !backlog.isEmpty {
          Section {
            ForEach(Array(backlog.enumerated()), id: \.element.id) { i, v in
              QueueRow(model: model, video: v, position: planned.count + i + 1, slot: nil)
                .tag(v.id)
                .contextMenu { VideoContextMenu(model: model, video: v, ids: Array(model.queueSelection)) }
            }
          } header: {
            SectionHeader(title: "Backlog", count: backlog.count, note: "Order follows score — \(model.settings.sort.displayName.lowercased())")
          }
        }
      } else {
        ForEach(Array(tabRows.enumerated()), id: \.element.id) { i, v in
          QueueRow(model: model, video: v, position: i + 1, slot: nil)
            .tag(v.id)
            .contextMenu { VideoContextMenu(model: model, video: v, ids: Array(model.queueSelection)) }
        }
      }
    }
    .listStyle(.inset)
    .alternatingRowBackgrounds(.disabled)
    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
      model.typeDigit(press.characters, ids: model.queueSelection)
      return .handled
    }
    .onKeyPress(.space) {
      if let v = model.focusedVideo { model.previewVideo = v }
      return .handled
    }
    .onKeyPress(.return) {
      if let v = model.focusedVideo { model.openEditor(v.id, in: model.selectedVideoIds) }
      return .handled
    }
  }

  /// Planned rows map to Planner ops: dropping a row onto another planned row swaps their days.
  private func movePlanned(_ planned: [(PlanSlot, Video)], from: IndexSet, to: Int) {
    guard let src = from.first else { return }
    let dst = to > src ? to - 1 : to
    guard dst != src, dst < planned.count else { return }
    model.swap(planned[src].0.id, planned[dst].0.id)
  }

  // MARK: Filters (Q.S2)

  private var filterBar: some View {
    HStack(spacing: 8) {
      Picker("Sort", selection: Binding(get: { model.settings.sort }, set: { s in model.update { $0.sort = s } })) {
        ForEach(SortDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .help("Sort the unplanned backlog. Approved weeks don't change until you rebuild.")
      Button("Ties: older first") { model.show("Equal scores: older session first, then set order") }
        .buttonStyle(.plain).font(DS.Font.secondary).foregroundStyle(.secondary)
      Divider().frame(height: 16)
      Menu {
        Button("All sessions") { sessionFilter = nil }
        ForEach(model.sessions) { s in Button(Captions.setName(s.name)) { sessionFilter = s.id } }
      } label: { filterLabel("Session", sessionFilter.flatMap { model.sessionById[$0] }.map { Captions.setName($0.name) }) }
        .menuStyle(.borderlessButton).fixedSize()
      Menu {
        Button("All kinds") { kindFilter = nil }
        ForEach(Kind.allCases, id: \.self) { k in Button(k.displayName) { kindFilter = k } }
      } label: { filterLabel("Kind", kindFilter?.displayName) }
        .menuStyle(.borderlessButton).fixedSize()
      Menu {
        Button("Any score") { scoreFilter = nil }
        Button("80–100") { scoreFilter = 80...100 }
        Button("60–79") { scoreFilter = 60...79 }
        Button("40–59") { scoreFilter = 40...59 }
        Button("0–39") { scoreFilter = 0...39 }
      } label: { filterLabel("Score", scoreFilter.map { "\($0.lowerBound)–\($0.upperBound)" }) }
        .menuStyle(.borderlessButton).fixedSize()
      Spacer()
      TextField("Search tags", text: $search)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 100, maxWidth: 200)
      Menu {
        Toggle("Avoid overlapping clips within \(model.settings.avoidOverlapDays) days",
               isOn: Binding(get: { model.settings.avoidOverlap }, set: { v in model.update { $0.avoidOverlap = v } }))
        Divider()
        Button("Score mode") { model.scoreMode = true }
        Button("Per-platform sort…") { WindowManager.shared.showSettings(section: .queue) }
      } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize().help("More")
    }
    .controlSize(.regular)
    .padding(.horizontal, DS.Space.l)
    .padding(.vertical, 8)
  }

  private func filterLabel(_ title: String, _ value: String?) -> some View {
    HStack(spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      if let value { Text(value).fontWeight(.medium) }
    }
    .font(DS.Font.body)
  }
}

struct SectionHeader: View {
  let title: String
  let count: Int
  var note: String? = nil
  var body: some View {
    HStack(spacing: 6) {
      Text(title).font(DS.Font.bodyStrong).foregroundStyle(.primary)
      Text("\(count)").font(DS.Font.body.monospacedDigit()).foregroundStyle(.secondary)
      Spacer()
      if let note { Text(note).font(DS.Font.secondary).foregroundStyle(.tertiary) }
    }
  }
}

/// Q.S1: stat strip (n8n ref) whose tiles double as the tabs, plus the one primary action.
struct QueueHeader: View {
  @Bindable var model: AppModel

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      ForEach(QueueTab.allCases) { tab in
        Button { model.queueTab = tab; model.queueSelection = [] } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(tab.title).font(DS.Font.body).foregroundStyle(.secondary)
            Text("\(count(tab))").font(DS.Font.runway)
              .foregroundStyle(tab == .toScore && count(tab) > 0 ? Color.orange : Color.primary)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .frame(width: 150, alignment: .leading)
          .background(model.queueTab == tab ? Color.accentColor.opacity(0.10) : .clear)
          .overlay(alignment: .bottom) {
            Rectangle().fill(model.queueTab == tab ? Color.accentColor : .clear).frame(height: 2)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if tab != QueueTab.allCases.last { Divider().frame(height: 40) }
      }
      Spacer()
      Button {
        model.scoreMode = true
      } label: {
        Label(model.toScore.isEmpty ? "Score mode" : "Score \(model.toScore.count)", systemImage: "number")
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .help("Score mode (⇧⌘S) — the selected video's Edit is this screen's primary action")
      .disabled(model.toScore.isEmpty && model.queueTab != .ready)
      .padding(.trailing, DS.Space.l)
    }
    .padding(.top, 4)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func count(_ t: QueueTab) -> Int {
    switch t {
    case .ready: model.ordered.count
    case .toScore: model.toScore.count
    case .needsEdit: model.needsEdit.count
    case .excluded: model.excluded.count
    }
  }
}

/// Q.S3 row (56 pt).
struct QueueRow: View {
  @Bindable var model: AppModel
  let video: Video
  let position: Int
  let slot: PlanSlot?
  @State private var hover = false

  var body: some View {
    HStack(spacing: 12) {
      Text("\(position)").font(DS.Font.mono).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
      CoverThumb(video: video)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(model.title(video)).font(DS.Font.bodyStrong).lineLimit(1)
          if slot?.pinned == true { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
          if video.missing { StatusPill(text: "Missing", tint: .red, icon: "exclamationmark.triangle.fill") }
        }
        Text(model.setName(video)).font(DS.Font.secondary).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      StatusPill(text: video.kind.displayName, tint: video.kind == .talking ? .purple : .secondary)
      ScoreField(score: video.score) { model.setScore([video.id], $0) }
      Text("v\(model.versions(video))").font(DS.Font.secondary.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
      PlatformDots(model: model, videoId: video.id)
      Text(model.nextDateLabel(video) ?? "—").font(DS.Font.secondary).foregroundStyle(slot == nil ? .tertiary : .secondary)
        .frame(width: 78, alignment: .trailing)
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 11))
        .foregroundStyle(slot == nil ? Color.secondary.opacity(0.35) : Color.secondary)
        .opacity(hover ? 1 : 0)
        .frame(width: 14)
        .help(slot == nil ? "Order follows score. Change the score to move it." : "Drag onto another planned row to swap days")
    }
    .frame(height: DS.Row.queue)
    .contentShape(Rectangle())
    .onHover { hover = $0 }
    .opacity(video.excluded ? 0.6 : 1)
  }
}

struct PlatformDots: View {
  @Bindable var model: AppModel
  let videoId: String
  var body: some View {
    HStack(spacing: 3) {
      ForEach(Platform.allCases.sorted()) { p in
        let d = model.dot(videoId, p)
        StateDot(tint: d.tint, filled: d.filled, size: 7).help("\(p.displayName): \(d.label)")
      }
    }
    .frame(width: 60)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Platform.allCases.sorted().map { "\($0.displayName) \(model.dot(videoId, $0).label)" }.joined(separator: ", "))
  }
}

/// Q.S3.a inline score: type a number, ↑/↓ ±1, ⇧↑/↓ ±10, ↩ to commit, Esc to revert.
struct ScoreField: View {
  let score: Int?
  var width: CGFloat = 38
  var font: Font = DS.Font.score
  let onCommit: (Int?) -> Void
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField("–", text: $text)
      .textFieldStyle(.plain)
      .font(font)
      .multilineTextAlignment(.trailing)
      .frame(width: width)
      .focused($focused)
      .onAppear { text = score.map(String.init) ?? "" }
      .onChange(of: score) { _, s in if !focused { text = s.map(String.init) ?? "" } }
      .onChange(of: focused) { _, f in if !f { commit() } }
      .onSubmit { commit() }
      .onExitCommand { text = score.map(String.init) ?? ""; focused = false }
      .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
        let step = press.modifiers.contains(.shift) ? 10 : 1
        let cur = Int(text) ?? score ?? 50
        let next = min(100, max(0, cur + (press.key == .upArrow ? step : -step)))
        text = "\(next)"
        return .handled
      }
      .help("Score 0–100 · ↑/↓ ±1 · ⇧↑/↓ ±10")
  }

  private func commit() {
    let t = text.trimmingCharacters(in: .whitespaces)
    let v: Int? = t.isEmpty ? nil : Int(t).map { min(100, max(0, $0)) }
    if t.isEmpty == false && v == nil { text = score.map(String.init) ?? ""; return }
    if v != score { onCommit(v) }
    text = v.map(String.init) ?? ""
  }
}

/// Q.S5 bulk bar (Later ref): "3 selected" · score · kind · exclude · add to week.
struct BulkBar: View {
  @Bindable var model: AppModel
  let ids: [String]
  let onClear: () -> Void
  @State private var score = ""

  var body: some View {
    HStack(spacing: 10) {
      Text("\(ids.count) selected").font(DS.Font.bodyStrong)
      Button("Deselect all", action: onClear).buttonStyle(.bordered)
      Spacer()
      HStack(spacing: 4) {
        TextField("Score", text: $score).textFieldStyle(.roundedBorder).frame(width: 64)
          .onSubmit(apply)
        Button("Set score", action: apply).disabled(Int(score) == nil)
      }
      Menu("Kind") {
        ForEach(Kind.allCases, id: \.self) { k in Button(k.displayName) { model.setKind(ids, k) } }
      }
      .fixedSize()
      Button("Exclude", systemImage: "minus.circle") { model.setExcluded(ids, true) }
      Button("Add to week", systemImage: "calendar.badge.plus") { model.addToWeek(ids) }
    }
    .buttonStyle(.bordered)
    .padding(.horizontal, DS.Space.l)
    .padding(.vertical, 8)
    .background(Color.accentColor.opacity(0.07))
  }

  private func apply() {
    guard let n = Int(score) else { return }
    model.setScore(ids, n)
    score = ""
  }
}
