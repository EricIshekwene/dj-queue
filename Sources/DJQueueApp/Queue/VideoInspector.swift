import DJQCore
import SwiftUI

/// Q.S4 inspector (Linear ref): cover, properties, posts, actions; advanced under "More".
struct VideoInspector: View {
  @Bindable var model: AppModel
  let video: Video
  @State private var notes = ""
  @State private var sliderScore: Double = 50
  @State private var pinDate = Date()
  @State private var showPin = false
  @State private var showMore = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        if video.type == .long { longform } else { properties }
        postsSection
        if video.type == .short { actions }
        more
      }
      .padding(DS.Space.l)
    }
    .onAppear(perform: load)
    .onChange(of: video.id) { load() }
    .onChange(of: video.score) { sliderScore = Double(video.score ?? 50) }
  }

  private func load() {
    notes = video.notes
    sliderScore = Double(video.score ?? 50)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      CoverThumb(video: video, width: video.type == .long ? 160 : 96, height: video.type == .long ? 90 : 171, radius: 6)
        .onTapGesture { model.previewVideo = video }
        .help("Preview (Space)")
      VStack(alignment: .leading, spacing: 6) {
        Text(model.title(video)).font(DS.Font.title).lineLimit(3)
        Text(model.setName(video)).font(DS.Font.secondary).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          StatusPill(video: video)
          if video.type == .long { StatusPill(text: "Long-form", tint: .indigo) }
        }
        Text(Fmt.duration(video.duration) + (video.audio.map { " · \($0)" } ?? ""))
          .font(DS.Font.mono).foregroundStyle(.secondary)
      }
    }
  }

  private var properties: some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow("Properties")
      PropertyRow("Score") {
        HStack(spacing: 8) {
          Slider(value: $sliderScore, in: 0...100, step: 1) { editing in
            if !editing { model.setScore([video.id], Int(sliderScore)) }
          }
          ScoreField(score: video.score, width: 34) { model.setScore([video.id], $0) }
        }
      }
      PropertyRow("Kind") {
        Picker("Kind", selection: Binding(get: { video.kind }, set: { model.setKind([video.id], $0) })) {
          ForEach(Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
      }
      PropertyRow("Next") {
        Text(model.nextDateLabel(video) ?? "Not planned").foregroundStyle(model.nextSlotByVideo[video.id] == nil ? .secondary : .primary)
      }
      PropertyRow("Versions") { Text(model.versions(video) == 1 ? "v1" : "v1 – v\(model.versions(video))") }
      PropertyRow("Notes") {
        TextField("Add a note", text: $notes, axis: .vertical)
          .lineLimit(1...4)
          .textFieldStyle(.roundedBorder)
          .onSubmit { model.setNotes(video.id, notes) }
          .onChange(of: notes) { _, n in
            let id = video.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if n == notes && n != video.notes { model.setNotes(id, n) } }
          }
      }
    }
  }

  @State private var longURL = ""
  private var longform: some View {
    VStack(alignment: .leading, spacing: 8) {
      Eyebrow("Long-form")
      if let u = video.longformURL {
        PropertyRow("Posted") { Link(u, destination: URL(string: u) ?? URL(string: "https://youtube.com")!).lineLimit(1) }
      } else {
        Text("Paste the YouTube URL once it's live. The file moves to Posted/Longform.")
          .font(DS.Font.secondary).foregroundStyle(.secondary)
        Button("Mark posted…") { model.longformTarget = video }.buttonStyle(.borderedProminent)
        Text("Reminder: run a Test & Compare on the thumbnail.").font(DS.Font.secondary).foregroundStyle(.tertiary)
      }
    }
  }

  private var postsSection: some View {
    let latest = model.latestPosts(video.id)
    return VStack(alignment: .leading, spacing: 6) {
      Eyebrow("Posts")
      if video.type == .long {
        Text("Tracking only").font(DS.Font.secondary).foregroundStyle(.secondary)
      } else if latest.isEmpty {
        Text(video.alreadyPostedOn.isEmpty ? "Not planned yet" : "Already on \(video.alreadyPostedOn.map(\.shortName).joined(separator: ", "))")
          .font(DS.Font.secondary).foregroundStyle(.secondary)
      } else {
        ForEach(Platform.allCases.sorted()) { p in
          if let post = latest[p] {
            HStack(spacing: 8) {
              PlatformGlyph(platform: p, tint: post.state.tint, size: 18)
              Text(Fmt.day(post.scheduledAt, tz: model.tz, style: "EEE d MMM")).font(DS.Font.secondary).foregroundStyle(.secondary)
              Spacer()
              if post.attemptNo > 1 { Text("#\(post.attemptNo)").font(DS.Font.mono).foregroundStyle(.secondary) }
              StatusPill(post: post, now: model.now)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(p.displayName): \(post.state.displayName.lowercased())")
            .onTapGesture { model.postsSelection = post.id; model.screen = .posts }
            .contextMenu { PostContextMenu(model: model, post: post) }
          }
        }
      }
    }
  }

  private var actions: some View {
    VStack(alignment: .leading, spacing: 2) {
      Eyebrow("Actions").padding(.bottom, 4)
      Button { model.openEditor(video.id, in: model.selectedVideoIds) } label: {
        Label("Edit", systemImage: "slider.horizontal.below.rectangle").frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .padding(.bottom, 6)
      .help("⌘E")
      actionRow("Pin to date…", "pin") { showPin = true }
        .popover(isPresented: $showPin, arrowEdge: .leading) {
          VStack(alignment: .trailing, spacing: 10) {
            DatePicker("Date", selection: $pinDate, in: model.now..., displayedComponents: .date)
              .datePickerStyle(.graphical).labelsHidden()
            Button("Pin") { model.pin(video.id, date: pinDate); showPin = false }.buttonStyle(.borderedProminent)
          }
          .padding(12)
        }
      actionRow("Post today", "bolt") { model.postToday(video.id) }
      actionRow("Skip next", "forward.end") { model.skipNext(video.id) }
        .disabled(model.nextSlotByVideo[video.id] == nil)
      actionRow(video.excluded ? "Include" : "Exclude", video.excluded ? "plus.circle" : "minus.circle") {
        model.setExcluded([video.id], !video.excluded)
      }
    }
  }

  private func actionRow(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) {
      Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var more: some View {
    DisclosureGroup(isExpanded: $showMore) {
      VStack(alignment: .leading, spacing: 8) {
        if video.type == .short {
          Text("Sort per platform — applies to all videos").font(DS.Font.secondary).foregroundStyle(.secondary)
          ForEach(model.settings.activePlatforms) { p in
            PropertyRow(p.displayName) {
              Picker(p.displayName, selection: Binding<SortDirection?>(
                get: { model.settings.sortOverrides[p] },
                set: { v in model.update { $0.sortOverrides[p] = v } })) {
                  Text("Default").tag(SortDirection?.none)
                  ForEach(SortDirection.allCases, id: \.self) { Text($0.displayName).tag(SortDirection?.some($0)) }
                }
                .labelsHidden()
            }
          }
          Divider()
          RepostMenu(model: model, videoId: video.id).fixedSize()
          HStack {
            Button("Duplicate version") { model.duplicateVersion(video.id) }
            Button("Re-render") { model.reRender(video.id) }
          }
        }
        PropertyRow("State") { Text(video.state.displayName) }
        PropertyRow("Audio") { Text(video.audio ?? "—") }
        PropertyRow("File") {
          Button((video.file as NSString).lastPathComponent) {
            if let u = try? model.store.fileURL(for: video) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
          }
          .buttonStyle(.link).lineLimit(1).help("Reveal in Finder")
        }
        PropertyRow("ID") { Text(video.id).font(DS.Font.mono).textSelection(.enabled).lineLimit(1) }
      }
      .padding(.top, 6)
    } label: {
      Text("More").font(DS.Font.bodyStrong)
    }
  }
}
