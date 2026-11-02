import DJQCore
import Observation
import SwiftUI

/// UI state the pipeline screens (Score, Edit, Queue) keep outside their views, so it survives view rebuilds and
/// snapshot setups can drive it: typed grid scores and Score's optimistic "saved" set. (List search, chips,
/// filters and sort are in `ListPrefs`.)
@MainActor
@Observable
final class PipelineUIState {
  static let shared = PipelineUIState()
  /// Score grid: clip id → what Eric typed (not saved yet).
  var typedScores: [String: String] = [:]
  /// Score: clips saved/skipped-away in this session that the list may still contain until the refresh lands.
  var scoreHidden: Set<String> = []

  /// A typed value that is a valid score, else nil.
  static func score(_ s: String?) -> Int? {
    guard let s, let n = Int(s.trimmingCharacters(in: .whitespaces)), (0...100).contains(n) else { return nil }
    return n
  }
}

/// One Edit status chip: why clips are in Edit ("No crop", "Too long for X", "File missing", …), derived from
/// `AppModel.issuesByVideo`. Labels, tooltips and order come from DJQCore (`ValidationIssue.chipText`,
/// `Kind.chipHelp`, `Kind.chipOrder`), the same words `djq` prints.
struct EditFilter: Hashable, Identifiable {
  var kind: ValidationIssue.Kind
  var platform: Platform?
  var id: String { "\(kind.rawValue)-\(platform?.rawValue ?? "all")" }

  var title: String { ValidationIssue(kind: kind, platform: platform, message: "").chipText }
  var help: String { kind.chipHelp }

  func matches(_ issues: [ValidationIssue]) -> Bool {
    issues.contains { $0.kind == kind && $0.platform == platform }
  }

  /// Chip order: sent back first, then missing pieces, then hard blocks.
  var order: Int { kind.chipOrder }
}

extension AppModel {
  /// Bulk action through the shared flow (confirmation sheet for > 1 clip, dry run, undo toast). `body` runs off
  /// the main thread with the model's `BulkActions`.
  func pipelineBulk(_ title: String, verb: String, ids: [String], changes: [DSChangeList.Change] = [], done: String? = nil,
                    _ body: @escaping @Sendable (BulkActions, Bool) throws -> BulkResult) {
    let b = bulk
    requestBulk(BulkRequest(title: title, verb: verb, ids: ids, changes: changes, doneMessage: done) { dry in try body(b, dry) })
  }

  /// A disabled native menu item's reason, appended to its title (menu items show no tooltip): " — already posted
  /// on X" from "Already posted on X — it can't leave the plan; …". Empty when the item is enabled.
  static func menuReason(_ why: String?) -> String {
    guard let why, let first = why.components(separatedBy: " — ").first, !first.isEmpty else { return "" }
    return " — " + first.prefix(1).lowercased() + first.dropFirst()
  }

  /// "Clip" / "N clips".
  static func pipelineClips(_ n: Int) -> String { n == 1 ? "1 clip" : "\(n) clips" }

  /// Saves scores Eric typed per clip (Score grid "Save scores"). Each value is his explicit choice for that one
  /// clip, so there is no confirmation sheet; clips with the same score share one batch, and the toast's Undo
  /// reverts every batch (⌘Z reverts the last one).
  func pipelineSaveScores(_ scores: [String: Int]) {
    guard !scores.isEmpty else { return }
    splitEditorSession()
    let b = bulk
    let groups = Dictionary(grouping: scores.keys.sorted(), by: { scores[$0]! })
    Task.detached(priority: .userInitiated) {
      var batches: [String] = [], changed = 0, failure: String?
      for (score, ids) in groups.sorted(by: { $0.key < $1.key }) {
        do {
          let r = try b.setScore(ids, score)
          changed += r.changed.count
          if let id = r.batchId { batches.append(id) }
        } catch {
          failure = error.localizedDescription
        }
      }
      let (fail, done, all) = (failure, changed, batches)
      await MainActor.run {
        self.refresh()
        if let failure = fail { self.show(failure, error: true); return }
        for id in all { self.undoHistory.push(id, label: "Saved \(done) score\(done == 1 ? "" : "s")") }
        self.show(DSToastModel(message: "Saved \(done) score\(done == 1 ? "" : "s")", tone: .success,
                               actionTitle: all.isEmpty ? nil : "Undo",
                               action: all.isEmpty ? nil : { for id in all.reversed() { self.undo(batch: id) } }, duration: 6))
      }
    }
  }

  /// The first week (from this one) that still has a free day for `count` clips, as its week-start key.
  func pipelineWeekWithRoom() -> String {
    let perDay = max(1, settings.postsPerDay)
    var used: [String: Int] = [:]
    for s in upcomingSlots { used[s.date, default: 0] += 1 }
    var week = dm.weekStart(of: now)
    for _ in 0..<12 {
      if dm.weekDays(week).contains(where: { $0 >= todayKey && used[$0, default: 0] < perDay }) { return week }
      week = dm.addDays(week, 7)
    }
    return dm.weekStart(of: now)
  }
}

/// Bookkeeping for the pipeline's own clip layouts (Score single/grid, Queue cards) — what ClipCollection does
/// internally: registers the ids for ⌘A / Select all, drops selected ids that left the list, and asks for preview
/// proxies of what's on screen (most important first) after a short settle.
struct PipelineClipFeed: ViewModifier {
  let model: AppModel
  let screen: Screen
  let ids: [String]
  /// Clips to preload/play, most important first.
  let playIds: [String]
  var layout: PreviewPlayback.Layout = .cards
  /// Hovered (or keyboard-focused) clip — grids with "play on hover only" fetch only it and prefetch its neighbours.
  var hovered: String? = nil

  func body(content: Content) -> some View {
    content
      .onAppear { register(ids) }
      .onChange(of: ids) { _, new in register(new) }
      .task(id: playIds.joined(separator: ",") + "|\(model.playback.autoplay)|\(model.playback.loop.rawValue)"
            + "|\(model.playback.gridHoverOnly)|\(hovered ?? "")"
            // Edits change preview stamps: visible clips re-ask for their new proxies (round 4 S6).
            + "|" + playIds.map { model.previewStamp($0) }.joined(separator: ",")) {
        try? await Task.sleep(for: .milliseconds(model.frozen ? 0 : 250))
        guard !Task.isCancelled, model.playback.autoplay else { return }
        let t = PreviewPlayback.proxyTargets(model.playback, layout: layout, visible: playIds, hovered: hovered)
        model.requestProxies(t.now, prefetch: t.prefetch)
      }
  }

  private func register(_ new: [String]) {
    model.visibleIds[screen] = new
    let keep = Set(new)
    if let sel = model.selection[screen], !sel.isSubset(of: keep) { model.selection[screen] = sel.intersection(keep) }
  }
}

extension View {
  func pipelineClipFeed(_ model: AppModel, _ screen: Screen, ids: [String], play: [String],
                        layout: PreviewPlayback.Layout = .cards, hovered: String? = nil) -> some View {
    modifier(PipelineClipFeed(model: model, screen: screen, ids: ids, playIds: play, layout: layout, hovered: hovered))
  }
}

/// The view toggle (DSViewModeSwitcher look) with a tooltip per mode that says what the layout is for, not just its
/// name ("One clip at a time, keyboard scoring"). Modes without a tip fall back to their name.
struct PipelineViewModeSwitcher: View {
  @Binding var mode: DSViewMode
  var modes: [DSViewMode] = DSViewMode.allCases
  var tips: [DSViewMode: String] = PipelineViewModeSwitcher.clipTips

  /// Edit / Queue: the four layouts of a clip list.
  static let clipTips: [DSViewMode: String] = [
    .wide: "Show clips as cards with their actions",
    .grid: "Show many clips at a glance",
    .single: "Show one big clip at a time",
    .list: "Show clips as compact rows",
  ]

  var body: some View {
    DSSegmented(selection: $mode, segments: modes.map { DSSegment(value: $0, icon: $0.icon, tooltip: tips[$0] ?? $0.help) })
  }
}

/// A native `Menu` styled as a labelled ghost capsule inside the bulk bar (`Kind ▾`, `Caption ▾`): title + chevron,
/// no leading icon (the chevron marks it as a menu and keeps the bar inside its 720 pt).
struct PipelineBulkMenu<Content: View>: View {
  let title: String
  var tooltip: String
  @ViewBuilder var content: Content

  init(_ title: String, tooltip: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.tooltip = tooltip
    self.content = content()
  }

  var body: some View {
    Menu {
      content
    } label: {
      HStack(spacing: 6) {
        Text(title)
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.6)
      }
    }
    .menuStyle(.button)
    .buttonStyle(DSBulkActionStyle())
    .menuIndicator(.hidden)
    .fixedSize()
    .dsTooltip(tooltip)
  }
}

/// ⋯ for a card: a native menu behind a ghost circle (DSIconButton look), tooltipped.
struct PipelineMoreMenu<Content: View>: View {
  var tooltip = "More actions"
  @ViewBuilder var content: Content

  init(tooltip: String = "More actions", @ViewBuilder content: () -> Content) {
    self.tooltip = tooltip
    self.content = content()
  }

  var body: some View {
    Menu {
      content
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
    }
    .menuStyle(.button)
    .buttonStyle(DSButtonStyle(variant: .ghost, size: .sm, iconOnly: true))
    .menuIndicator(.hidden)
    .fixedSize()
    .dsTooltip(tooltip)
    .accessibilityLabel(tooltip)
  }
}

/// Date picker popover body ("Pin to date…", "Pin to days…"): a graphical calendar from today and one primary.
struct PipelineDatePopover: View {
  let title: String
  var detail: String?
  let verb: String
  let minDate: Date
  let onPick: (Date) -> Void
  @State private var date: Date

  init(title: String, detail: String? = nil, verb: String, minDate: Date, initial: Date? = nil, onPick: @escaping (Date) -> Void) {
    self.title = title
    self.detail = detail
    self.verb = verb
    self.minDate = minDate
    self.onPick = onPick
    _date = State(initialValue: initial ?? minDate)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        if let detail { Text(detail).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true) }
      }
      DatePicker("Date", selection: $date, in: minDate..., displayedComponents: .date)
        .datePickerStyle(.graphical)
        .labelsHidden()
      HStack {
        Spacer()
        DSButton(verb, variant: .primary, size: .sm) { onPick(date) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(DS.space.xs)
  }
}
