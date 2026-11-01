import DJQCore
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
  case all, short, long, toScore, excluded, missing
  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: "All"
    case .short: "Short"
    case .long: "Long-form"
    case .toScore: "To score"
    case .excluded: "Excluded"
    case .missing: "Missing"
    }
  }
}

/// L.L (Later ref): sessions list → video table / grid, bulk bar on multi-select, inspector.
struct LibraryView: View {
  @Bindable var model: AppModel
  @State private var filter: LibraryFilter = .all
  @State private var search = ""
  @State private var sortOrder = [KeyPathComparator(\LibraryRow.order)]

  private var rows: [LibraryRow] {
    model.videos
      .filter { model.librarySession == nil || $0.sessionId == model.librarySession }
      .filter { v in
        switch filter {
        case .all: true
        case .short: v.type == .short
        case .long: v.type == .long
        case .toScore: v.type == .short && v.score == nil && !v.excluded
        case .excluded: v.excluded
        case .missing: v.missing || !v.inManifest
        }
      }
      .filter { search.isEmpty || $0.tag.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
      .map { LibraryRow(model: model, video: $0) }
      .sorted(using: sortOrder)
  }

  var body: some View {
    HStack(spacing: 0) {
      SessionList(model: model).frame(width: 200)
      Divider()
      VStack(spacing: 0) {
        if model.librarySelection.count > 1 {
          BulkBar(model: model, ids: Array(model.librarySelection), onClear: { model.librarySelection = [] })
        } else {
          toolbar
        }
        Divider()
        if model.sessions.isEmpty {
          EmptyState(symbol: "folder.badge.questionmark", title: "No sessions found",
                     subtitle: "Add a session folder with a videos.json under \(model.store.paths.sessions.path).")
        } else if rows.isEmpty {
          EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No videos match", buttonTitle: "Show all") { filter = .all; search = "" }
        } else if model.libraryGrid {
          gridView
        } else {
          table
        }
      }
    }
    .inspector(isPresented: $model.showInspector) {
      Group {
        if model.librarySelection.count == 1, let v = model.video(model.librarySelection.first!) {
          VStack(spacing: 0) {
            if !v.inManifest && !model.keptRemoved.contains(v.id) { removedNotice(v) }
            VideoInspector(model: model, video: v)
          }
        } else {
          EmptyState(symbol: "sidebar.right", title: model.librarySelection.count > 1 ? "\(model.librarySelection.count) selected" : "No selection")
        }
      }
      .inspectorColumnWidth(min: 280, ideal: DS.inspectorWidth, max: 380)
    }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      ForEach(LibraryFilter.allCases) { f in
        let n = count(f)
        if f != .short && (f == .all || n > 0) {
          Chip(title: "\(f.title) \(n)", selected: filter == f, tint: f == .missing ? .red : .accentColor) { filter = f }
            .fixedSize()
        }
      }
      Spacer(minLength: 8)
      TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 180)
      Picker("View", selection: $model.libraryGrid) {
        Image(systemName: "list.bullet").tag(false)
        Image(systemName: "square.grid.2x2").tag(true)
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
    .padding(.horizontal, DS.Space.l)
    .padding(.vertical, 8)
  }

  private func count(_ f: LibraryFilter) -> Int {
    let vs = model.videos.filter { model.librarySession == nil || $0.sessionId == model.librarySession }
    switch f {
    case .all: return vs.count
    case .short: return vs.filter { $0.type == .short }.count
    case .long: return vs.filter { $0.type == .long }.count
    case .toScore: return vs.filter { $0.type == .short && $0.score == nil && !$0.excluded }.count
    case .excluded: return vs.filter(\.excluded).count
    case .missing: return vs.filter { $0.missing || !$0.inManifest }.count
    }
  }

  private var table: some View {
    Table(rows, selection: $model.librarySelection, sortOrder: $sortOrder) {
      TableColumn("Video", value: \.name) { r in
        HStack(spacing: 10) {
          CoverThumb(video: r.video, width: r.video.type == .long ? 48 : 22, height: r.video.type == .long ? 27 : 39)
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
              Text(r.name).font(DS.Font.bodyStrong).lineLimit(1)
              if model.relinked.contains(r.id) {
                Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.blue).help("Relinked after a rename")
              }
            }
            Text(model.setName(r.video)).font(DS.Font.secondary).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .foregroundStyle(r.video.missing ? Color.red : Color.primary)
        .contextMenu { VideoContextMenu(model: model, video: r.video, ids: Array(model.librarySelection)) }
      }
      .width(min: 160, ideal: 190)
      TableColumn("Type", value: \.typeLabel) { r in
        if r.video.type == .long { StatusPill(text: "Long-form", tint: .indigo) } else { Text("Short").foregroundStyle(.secondary) }
      }
      .width(76)
      TableColumn("Kind", value: \.kindLabel) { r in Text(r.kindLabel).foregroundStyle(.secondary) }.width(58)
      TableColumn("Length", value: \.duration) { r in Text(Fmt.duration(r.duration)).font(DS.Font.mono) }.width(54)
      TableColumn("Audio", value: \.audio) { r in Text(r.audio).foregroundStyle(.secondary) }.width(66)
      TableColumn("Score", value: \.scoreSort) { r in
        if r.video.type == .short {
          ScoreField(score: r.video.score, width: 34) { model.setScore([r.id], $0) }
        }
      }
      .width(52)
      TableColumn("State", value: \.stateLabel) { r in stateCell(r.video) }.width(min: 80, ideal: 96)
      TableColumn("Posted on", value: \.postedOn) { r in
        HStack(spacing: 2) {
          if r.video.type == .long {
            if r.video.longformURL != nil { PlatformGlyph(platform: .youtube, tint: .green, size: 16) }
            else { Button("Mark posted") { model.longformTarget = r.video }.controlSize(.small) }
          } else {
            ForEach(r.postedPlatforms) { p in PlatformGlyph(platform: p, tint: .green, size: 16) }
          }
        }
      }
      .width(min: 80, ideal: 96)
    }
    .onKeyPress(.space) {
      if let id = model.librarySelection.first, let v = model.video(id) { model.previewVideo = v }
      return .handled
    }
    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
      model.typeDigit(press.characters, ids: model.librarySelection)
      return .handled
    }
  }

  @ViewBuilder private func stateCell(_ v: Video) -> some View {
    if v.missing {
      StatusPill(text: "Missing", tint: .red, icon: "exclamationmark.triangle.fill", loud: true)
    } else if !v.inManifest && !model.keptRemoved.contains(v.id) {
      StatusPill(text: "Not in videos.json", tint: .orange, icon: "questionmark.circle")
    } else if v.type == .short && v.score == nil && !v.excluded {
      StatusPill(text: "To score", tint: .orange)
    } else {
      StatusPill(video: v)
    }
  }

  private var gridView: some View {
    ScrollView {
      let groups = Dictionary(grouping: rows, by: { $0.video.sessionId })
      VStack(alignment: .leading, spacing: 20) {
        ForEach(model.sessions.filter { groups[$0.id] != nil }) { s in
          VStack(alignment: .leading, spacing: 10) {
            Text(Captions.setName(s.name)).font(DS.Font.title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 14) {
              ForEach(groups[s.id] ?? []) { r in
                let sel = model.librarySelection.contains(r.id)
                VStack(alignment: .leading, spacing: 4) {
                  ZStack(alignment: .topLeading) {
                    CoverThumb(video: r.video, width: 104, height: 185, radius: 6)
                    if sel { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).font(.system(size: 18)).padding(6) }
                    if r.video.missing { StatusPill(text: "Missing", tint: .red, loud: true).padding(6) }
                  }
                  .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(sel ? Color.accentColor : .clear, lineWidth: 2))
                  Text(r.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                  HStack(spacing: 4) {
                    Text(r.video.score.map(String.init) ?? "–").font(DS.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
                    Text(r.stateLabel).font(DS.Font.secondary).foregroundStyle(.tertiary)
                  }
                }
                .frame(width: 104)
                .contentShape(Rectangle())
                .onTapGesture {
                  if NSEvent.modifierFlags.contains(.command) {
                    if sel { model.librarySelection.remove(r.id) } else { model.librarySelection.insert(r.id) }
                  } else { model.librarySelection = [r.id] }
                }
                .contextMenu { VideoContextMenu(model: model, video: r.video, ids: Array(model.librarySelection)) }
              }
            }
          }
        }
      }
      .padding(DS.Space.l)
    }
  }

  /// L.S5: removed from videos.json → Keep / Exclude.
  private func removedNotice(_ v: Video) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Removed from videos.json", systemImage: "questionmark.circle.fill").font(DS.Font.bodyStrong).foregroundStyle(.orange)
      Text("The record and its history are kept. Keep posting it, or exclude it?").font(DS.Font.secondary).foregroundStyle(.secondary)
      HStack {
        Button("Keep") { model.keepRemoved(v.id) }
        Button("Exclude") { model.setExcluded([v.id], true); model.keepRemoved(v.id) }.buttonStyle(.borderedProminent)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.1))
  }
}

struct LibraryRow: Identifiable {
  let video: Video
  let name: String
  let order: String
  let postedPlatforms: [Platform]
  var id: String { video.id }

  @MainActor init(model: AppModel, video: Video) {
    self.video = video
    name = model.title(video)
    order = String(format: "%@-%03d-%08.1f", model.sessionById[video.sessionId]?.date ?? "", video.part ?? 0, video.start ?? 0)
    let posted = Set(model.latestPosts(video.id).values.filter { $0.state == .posted }.map(\.platform)).union(video.alreadyPostedOn)
    postedPlatforms = posted.sorted()
  }

  var typeLabel: String { video.type == .long ? "Long-form" : "Short" }
  var kindLabel: String { video.kind.displayName }
  var duration: Double { video.duration }
  var audio: String { video.audio ?? "—" }
  var scoreSort: Int { video.score ?? -1 }
  var stateLabel: String { video.missing ? "Missing" : video.state.displayName }
  var postedOn: String { postedPlatforms.map(\.shortName).joined() }
}

/// L.S1: sessions with counts (short / long / missing), missing-session flag.
struct SessionList: View {
  @Bindable var model: AppModel

  var body: some View {
    List(selection: Binding<String?>(get: { model.librarySession ?? "__all" }, set: { model.librarySession = $0 == "__all" ? nil : $0 })) {
      row(title: "All videos", short: model.videos.filter { $0.type == .short }.count, long: model.videos.filter { $0.type == .long }.count,
          missing: model.videos.filter(\.missing).count, flagged: false)
        .tag("__all")
      Section("Sessions") {
        ForEach(model.sessions.sorted { ($0.date ?? "") > ($1.date ?? "") }) { s in
          let vs = model.videos.filter { $0.sessionId == s.id }
          row(title: Captions.setName(s.name), subtitle: s.date, short: vs.filter { $0.type == .short }.count,
              long: vs.filter { $0.type == .long }.count, missing: vs.filter(\.missing).count, flagged: s.missing)
            .tag(s.id)
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func row(title: String, subtitle: String? = nil, short: Int, long: Int, missing: Int, flagged: Bool) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title).font(DS.Font.bodyStrong).lineLimit(1)
        if flagged { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Session folder missing") }
      }
      HStack(spacing: 6) {
        if let subtitle { Text(subtitle).foregroundStyle(.tertiary) }
        Text("\(short) short")
        if long > 0 { Text("· \(long) long") }
        if missing > 0 { Text("· \(missing) missing").foregroundStyle(.red) }
      }
      .font(DS.Font.secondary).foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
  }
}
