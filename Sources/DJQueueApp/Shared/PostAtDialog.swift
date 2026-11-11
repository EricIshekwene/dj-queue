import DJQCore
import SwiftUI

/// Round 21: "Post at a set time" (DECISIONS-R21.md D12–D14), shown by `MainWindowView` while `model.postAtRequest` is set
/// (over the editor too). Patterns: Basecamp's "when would you like to post this?" (day, time, one button), Shopify's
/// date + time with the time zone in words, Buffer's quick time chips, Klaviyo's error under the time field.
///
/// ```
/// ┌ Post at a set time ──────────────────────────────────────────────── ✕ ┐
/// │ ▮ Saturday flyer · Photo · in Edit                                    │
/// │ [In 1 hour] [Tonight 7:00 PM] [Tomorrow 12:00 PM] [Saturday 6:00 PM]  │
/// │ ‹ November 2026 ›          Time [ 3:15 PM            ]                │
/// │ Mo Tu We Th Fr Sa Su       New York time                              │
/// │  9 10 11 (12) 13 14 15     Goes out                                   │
/// │ …                          ♪ TikTok ·········· Thu 12 Nov 3:15 PM     │
/// │                            ▷ YouTube ········· Photos skip it         │
/// │ [Use the regular schedule]                      [Cancel] [Set time]   │
/// └───────────────────────────────────────────────────────────────────────┘
/// ```
/// The rows come from `BulkActions.postAtPreview`, which runs the real thing and rolls it back, so the dialog can't
/// promise what Core won't do. Nothing is written until the primary button.
struct PostAtDialog: View {
  @Bindable var model: AppModel
  let request: PostAtRequest
  @State private var state = PostAtDialogModel()

  var body: some View {
    let s = state
    let p = s.picked
    let timed = s.timedIds
    DSDialog(AppModel.postAtTitle, description: "Every platform goes out at this minute. The regular schedule doesn't move.",
             icon: "clock", width: 640, onClose: s.close) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        PostAtItems(model: model, videos: s.videos)
        chips(p.at)
        HStack(alignment: .top, spacing: DS.space.lg) {
          PostAtDayGrid(model: model, day: $state.day, month: $state.month)
            .frame(width: PostAtDayGrid.width)
          VStack(alignment: .leading, spacing: DS.space.sm) {
            DSTextField("Time", placeholder: PostAtDialog.timePlaceholder, text: $state.timeText, icon: "clock",
                        hint: hint(p.at), error: p.problem, size: .lg, autoFocus: true, onSubmit: s.confirm)
              .whenBlurred(s.tidyTime)
            PostAtOutcome(model: model, videos: s.videos, at: p.at, problem: p.problem, checks: s.landed)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = s.error {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .font(DS.type.callout).foregroundStyle(DS.color.danger).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Couldn't set the time: \(error)")
        }
      }
    } footer: {
      HStack(spacing: DS.space.xs) {
        if !timed.isEmpty {
          DSButton(StageWording.useRegularSchedule, icon: "arrow.uturn.backward", variant: .ghost, disabledReason: s.busy ? "Working…" : nil,
                   tooltip: timed.count == s.ids.count ? "Take the set time off — it gets the next open day from the Queue"
                     : "Take the set time off the \(timed.count) that \(timed.count == 1 ? "has" : "have") one",
                   action: s.useRegular)
            .background(ScriptAnchor("Post at regular"))
        }
        Spacer(minLength: DS.space.md)
        DSButton("Cancel", variant: .ghost, shortcut: "esc", action: s.close).keyboardShortcut(.cancelAction)
          .background(ScriptAnchor("Post at cancel"))
        DSButton(s.primaryTitle, icon: "clock", variant: .primary, isLoading: s.busy, disabledReason: s.offReason,
                 tooltip: p.at.map { "Every platform goes out \(model.setTimeText($0))" }, shortcut: "↩", action: s.confirm)
          .keyboardShortcut(.defaultAction)
          .background(ScriptAnchor("Post at confirm"))
      }
      .frame(maxWidth: .infinity)
      .layoutPriority(1)
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
    .onAppear { s.start(model: model, ids: request.videoIds) }
    .task(id: p.at) { await s.check(p.at) }
  }

  static let timePlaceholder = "e.g. 7:30 PM"

  /// Under the time field: the day and time as they will be read back, and the time zone in words.
  private func hint(_ at: Date?) -> String {
    at.map { "\(model.setTimeText($0)) · \(model.timeZoneText)" } ?? model.timeZoneText
  }

  private func chips(_ at: Date?) -> some View {
    DSFlowLayout(spacing: 6) {
      ForEach(PostAtQuick.times(now: model.now, settings: model.settings)) { q in
        DSChip(q.title, isSelected: at == q.at, showsCheck: false, size: .sm, tooltip: model.setTimeText(q.at)) { state.pick(q.at) }
          .background(ScriptAnchor("Post at chip \(q.id)"))
      }
    }
  }
}

/// The dialog's state and rules, apart from its view so the live check can read what the dialog says (`live`) while it
/// drives the real controls.
@MainActor @Observable
final class PostAtDialogModel {
  /// The dialog on screen, for `PostAtScript`.
  static weak var live: PostAtDialogModel?

  @ObservationIgnored private weak var model: AppModel?
  private(set) var ids: [String] = []
  /// The picked day ("2026-11-14") and the time as typed.
  var day = ""
  var timeText = ""
  /// Any day of the month the grid shows.
  var month = ""
  /// What Core says the picked time would do, per item, and the time it was asked for.
  private(set) var checks: [String: PostAtCheck] = [:]
  private(set) var checkedAt: Date?
  /// A refusal from the write itself: it stays in the dialog.
  private(set) var error: String?
  private(set) var busy = false

  var videos: [Video] { ids.compactMap { model?.video($0) } }
  var timedIds: [String] { ids.filter { model?.setTime($0) != nil } }
  /// "Change time" once every item has one.
  var primaryTitle: String { !ids.isEmpty && timedIds.count == ids.count ? "Change time" : "Set time" }

  /// The picked time, or why it can't be one (the field's error).
  var picked: (at: Date?, problem: String?) {
    let text = timeText.trimmingCharacters(in: .whitespaces)
    guard let model, !text.isEmpty, !day.isEmpty else { return (nil, nil) }
    guard let m = PostAtClock.minutes(text) else { return (nil, "That isn't a time — try 7pm or 19:30") }
    do {
      let at = try Planner.exactDate(day: day, minutes: m, settings: model.settings)
      // The time it already has is never a problem, however close: nothing would change.
      if ids.allSatisfy({ model.setTime($0) == at }) { return (at, nil) }
      return (at, model.planner.exactTimeProblem(at))
    } catch {
      return (nil, error.localizedDescription)
    }
  }

  /// The checks for the picked time, once they have landed.
  var landed: [PostAtCheck]? {
    guard let at = picked.at, checkedAt == at else { return nil }
    let list = ids.compactMap { checks[$0] }
    return list.count == ids.count ? list : nil
  }

  /// Why the primary button is off (nil = it's on).
  var offReason: String? {
    let p = picked
    if let why = p.problem { return why }
    guard p.at != nil else { return "Pick a day and type a time" }
    guard let list = landed else { return nil }
    let open = list.filter { $0.blocker == nil }
    if open.isEmpty { return list.count == 1 ? list[0].blocker : "None of them can take this time" }
    if open.allSatisfy(\.unchanged) { return list.count == 1 ? "It already has this time" : "They already have this time" }
    return nil
  }

  /// The time it has, else the next round hour at least an hour away.
  func start(model: AppModel, ids: [String]) {
    Self.live = self
    guard self.model == nil else { return }
    self.model = model
    self.ids = ids
    let shared = ids.compactMap { model.setTime($0) }
    let has = shared.count == ids.count && Set(shared).count == 1 ? shared[0] : nil
    if let has, model.planner.exactTimeProblem(has) == nil { pick(has) } else { pick(PostAtQuick.nextRoundHour(model.now)) }
  }

  func pick(_ at: Date) {
    guard let dm = model?.dm else { return }
    day = dm.key(at)
    month = day
    timeText = PostAtClock.text(Fmt.minutesOfDay(at, calendar: dm.calendar))
    error = nil
  }

  /// "7pm" reads back as "7:00 PM" once the field is left.
  func tidyTime() {
    if let m = PostAtClock.minutes(timeText) { timeText = PostAtClock.text(m) }
  }

  /// Debounced, off the main thread: typing "7:30 pm" asks Core once.
  func check(_ at: Date?) async {
    guard let at, let model else { return }
    try? await Task.sleep(for: .milliseconds(180))
    guard !Task.isCancelled else { return }
    let (b, ids) = (model.bulk, ids)
    let out = await Task.detached(priority: .userInitiated) { PostAtCheck.run(b, ids: ids, at: at) }.value
    guard !Task.isCancelled else { return }
    checks = out
    checkedAt = at
  }

  func confirm() {
    tidyTime()
    guard let model, let at = picked.at, offReason == nil, !busy else { return }
    busy = true
    error = nil
    Task {
      let why = await model.postAt(ids: ids, at: at)
      busy = false
      if let why { error = why } else { close() }
    }
  }

  func useRegular() {
    guard let model, !busy else { return }
    busy = true
    error = nil
    Task {
      let why = await model.clearSetTime(ids: timedIds)
      busy = false
      if let why { error = why } else { close() }
    }
  }

  func close() { model?.postAtRequest = nil }
}

/// What Core says a time would do for one item: its preview, or why the preview couldn't run.
struct PostAtCheck: Sendable {
  var videoId: String
  var preview: Planner.ExactPreview?
  var failure: String?

  var blocker: String? { preview == nil ? (failure ?? "Couldn't check this time") : preview?.blocker }
  var unchanged: Bool { preview?.unchanged ?? false }

  static func run(_ bulk: BulkActions, ids: [String], at: Date) -> [String: PostAtCheck] {
    var out: [String: PostAtCheck] = [:]
    for id in ids {
      do {
        out[id] = PostAtCheck(videoId: id, preview: try bulk.postAtPreview(id, at: at))
      } catch {
        out[id] = PostAtCheck(videoId: id, failure: error.localizedDescription)
      }
    }
    return out
  }
}

/// The quick chips: sensible times a DJ posts at. One that has passed, or is too close to set, isn't offered.
struct PostAtQuick: Identifiable {
  let id: String
  let title: String
  let at: Date

  static func times(now: Date, settings: AppSettings) -> [PostAtQuick] {
    let dm = DayMath(settings: settings)
    let today = dm.key(now)
    let soon = now.addingTimeInterval(Planner.exactLead)
    var out = [PostAtQuick(id: "hour", title: "In 1 hour", at: inAnHour(now))]
    let tonight = dm.at(today, minutes: 19 * 60)
    if tonight >= soon { out.append(PostAtQuick(id: "tonight", title: "Tonight 7:00 PM", at: tonight)) }
    out.append(PostAtQuick(id: "tomorrow", title: "Tomorrow 12:00 PM", at: dm.at(dm.addDays(today, 1), minutes: 12 * 60)))
    // The coming Saturday evening: today when it is Saturday and 6 PM is still ahead.
    for i in 0..<8 {
      let d = dm.addDays(today, i)
      let at = dm.at(d, minutes: 18 * 60)
      if dm.calendar.component(.weekday, from: dm.date(d)) == 7, at >= soon {
        out.append(PostAtQuick(id: "saturday", title: "Saturday 6:00 PM", at: at))
        break
      }
    }
    return out
  }

  /// An hour from now, on the next five minutes.
  static func inAnHour(_ now: Date) -> Date {
    Date(timeIntervalSince1970: ((now.timeIntervalSince1970 + 3600) / 300).rounded(.up) * 300)
  }

  /// The next round hour at least an hour away (the dialog's first suggestion).
  static func nextRoundHour(_ now: Date) -> Date {
    Date(timeIntervalSince1970: ((now.timeIntervalSince1970 + 3600) / 3600).rounded(.up) * 3600)
  }
}

/// The item the time is for: thumbnail, name, what it is and where it stands. Several: the first thumbnails and a count.
private struct PostAtItems: View {
  @Bindable var model: AppModel
  let videos: [Video]

  var body: some View {
    HStack(spacing: DS.space.sm) {
      HStack(spacing: -10) {
        ForEach(videos.prefix(3)) { v in DSXThumb(model: model, video: v, width: 27) }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(DS.type.bodyMedium).foregroundStyle(DS.color.text).lineLimit(1)
        Text(subtitle).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(DS.space.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private var title: String {
    videos.count == 1 ? model.displayName(videos[0]) : "\(videos.count) items"
  }

  private var subtitle: String {
    guard videos.count == 1, let v = videos.first else {
      return videos.prefix(3).map(model.displayName).joined(separator: ", ") + (videos.count > 3 ? " and \(videos.count - 3) more" : "")
    }
    return "\(v.kindLabel) · \(where_(v))"
  }

  /// "in Edit" · "in the Queue" · "Thu 12 Nov on the regular schedule" · "set for Sat 14 Nov 3:15 PM".
  private func where_(_ v: Video) -> String {
    if let at = model.setTime(v.id) { return "set for \(model.setTimeText(at))" }
    if let s = model.nextSlotByVideo[v.id] { return "\(Fmt.day(model.dm.date(s.date), tz: model.tz, style: "EEE d MMM")) on the regular schedule" }
    switch ClipStage.of(v) {
    case .edit: return "in Edit"
    case .queue: return "in the Queue, waiting for a day"
    case .scheduled: return "scheduled"
    default: return "not in the Queue"
    }
  }
}

/// A compact month: ‹ November 2026 ›, weekday letters, one round cell per day. Past days are dimmed and can't be picked.
struct PostAtDayGrid: View {
  @Bindable var model: AppModel
  @Binding var day: String
  @Binding var month: String

  static let cell: CGFloat = 32
  static let width: CGFloat = cell * 7

  var body: some View {
    let dm = model.dm
    let anchor = month.isEmpty ? model.todayKey : month
    let days = CalendarRange.visible(.month, anchor: anchor, dm: dm).days(dm: dm)
    let bounds = CalendarRange.monthBounds(anchor, dm: dm)
    let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    VStack(alignment: .leading, spacing: DS.space.xxs) {
      HStack(spacing: 2) {
        Text(Fmt.day(dm.date(anchor), tz: model.tz, style: "MMMM yyyy")).font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
          .padding(.leading, DS.space.xs)
        Spacer(minLength: 0)
        DSIconButton("chevron.left", tooltip: "Show the month before", size: .sm,
                     disabledReason: bounds.first <= model.todayKey ? "Past days can't take a post" : nil) { step(-1) }
          .background(ScriptAnchor("Post at month back"))
        DSIconButton("chevron.right", tooltip: "Show the month after", size: .sm) { step(1) }
          .background(ScriptAnchor("Post at month next"))
      }
      HStack(spacing: 0) {
        ForEach(days.prefix(7), id: \.self) { d in
          Text(Fmt.day(dm.date(d), tz: model.tz, style: "EEEEEE")).font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
            .frame(width: Self.cell, height: 20)
        }
      }
      ForEach(weeks, id: \.self) { w in
        HStack(spacing: 0) {
          ForEach(w, id: \.self) { d in cell(d, inMonth: bounds.first <= d && d <= bounds.last) }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Day")
  }

  private func cell(_ d: String, inMonth: Bool) -> some View {
    let past = d < model.todayKey
    let label = Fmt.day(model.dm.date(d), tz: model.tz, style: "EEE d MMM")
    return PostAtDayCell(number: Fmt.day(model.dm.date(d), tz: model.tz, style: "d"), isSelected: d == day, isToday: d == model.todayKey,
                         isDim: past || !inMonth, isOff: past) {
      day = d
      if !inMonth { month = d }
    }
    .dsTooltip(past ? "Past days can't take a post" : nil)
    .accessibilityLabel(d == model.todayKey ? "Today, \(label)" : label)
    .background(ScriptAnchor("Post at day \(d)"))
  }

  private func step(_ n: Int) {
    month = CalendarRange.stepped(month.isEmpty ? model.todayKey : month, mode: .month, by: n, dm: model.dm)
  }
}

/// One day: the picked one is the near-black circle (selection, never blue), today has a ring.
private struct PostAtDayCell: View {
  let number: String
  let isSelected: Bool
  let isToday: Bool
  let isDim: Bool
  let isOff: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button { if !isOff { action() } } label: {
      Text(number)
        .font(isSelected || isToday ? DS.type.calloutSemibold.monospacedDigit() : DS.type.callout.monospacedDigit())
        .foregroundStyle(isSelected ? DS.color.primaryText : isDim ? DS.color.textTertiary : DS.color.text)
        .frame(width: PostAtDayGrid.cell - 4, height: PostAtDayGrid.cell - 4)
        .background(isSelected ? DS.color.primary : hovering && !isOff ? DS.color.hover : .clear, in: Circle())
        .overlay { if isToday && !isSelected { Circle().strokeBorder(DS.color.borderStrong) } }
        .frame(width: PostAtDayGrid.cell, height: PostAtDayGrid.cell)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// What the picked time does, straight from Core's dry run: a row per platform, the platforms left out and why, what it
/// replaces, and the reason in place of the rows when it can't be set.
private struct PostAtOutcome: View {
  @Bindable var model: AppModel
  let videos: [Video]
  let at: Date?
  /// The time field's own error: it is shown under the field, so the rows only step aside.
  let problem: String?
  let checks: [PostAtCheck]?

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xxs) {
      DSEyebrow(videos.count == 1 ? "Goes out" : "What happens")
      if at == nil || problem != nil {
        quiet(problem == nil ? "Pick a day and type a time to see when each platform goes out." : "Nothing is set until the time works.")
      } else if let checks {
        if checks.count == 1, let c = checks.first { one(c) } else { many(checks) }
      } else {
        ForEach(0..<4, id: \.self) { i in DSSkeleton(width: CGFloat(200 + (i * 31) % 60), height: 10).frame(height: Self.row) }
      }
    }
    .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
  }

  private static let row: CGFloat = 24

  private func quiet(_ text: String) -> some View {
    Text(text).font(DS.type.callout).foregroundStyle(DS.color.textTertiary).fixedSize(horizontal: false, vertical: true)
  }

  // MARK: One item

  @ViewBuilder private func one(_ c: PostAtCheck) -> some View {
    if let why = c.blocker {
      blocked(why)
    } else if let p = c.preview {
      ForEach(p.platforms, id: \.platform) { l in
        line(l.platform, text: model.setTimeText(l.at) + (l.retry ? " · retry" : ""), dim: false,
             help: l.moved ? "Moved out of YouTube's quiet hours" : l.retry ? "It goes out as the retry of the post that failed" : nil)
      }
      ForEach(p.skipped, id: \.platform) { s in
        line(s.platform, text: Self.short(s, video: videos.first), dim: true, help: Self.long(s, video: videos.first))
      }
      ForEach(notes(p), id: \.self) { n in note(n) }
    }
  }

  /// YouTube's move and a shared minute first, then where it comes from.
  private func notes(_ p: Planner.ExactPreview) -> [String] {
    var out = p.notes
    if p.unchanged { return ["It already has this time"] }
    for s in p.replaces {
      if let had = s.exactAt {
        out.append("Replaces its set time, \(model.setTimeText(had))")
      } else {
        out.append("Leaves \(Fmt.day(model.dm.date(s.date), tz: model.tz, style: "EEE d MMM")) on the regular schedule")
      }
    }
    if let v = videos.first, ClipStage.of(v) == .edit { out.append("Leaves Edit: setting a time sends it") }
    return out
  }

  private static func short(_ s: Planner.ExactPreview.Skipped, video: Video?) -> String {
    switch s.reason {
    case .off: video?.isPhoto == true && !s.platform.supportsPhotos ? "Photos skip it" : "Off for it"
    case .posted: "Already posted"
    case .retrying: "Retries by itself"
    case .failed: "Failed — waits in Posts"
    case .skipped: "Skipped"
    case .history: "Already had its post"
    }
  }

  private static func long(_ s: Planner.ExactPreview.Skipped, video: Video?) -> String {
    s.reason == .off && video?.isPhoto == true && !s.platform.supportsPhotos ? PhotoRules.youtubeReason : s.why
  }

  // MARK: Several items

  @ViewBuilder private func many(_ checks: [PostAtCheck]) -> some View {
    ForEach(checks, id: \.videoId) { c in
      let name = model.video(c.videoId).map(model.displayName) ?? "Missing item"
      HStack(spacing: DS.space.xs) {
        Image(systemName: c.blocker == nil ? "clock" : "minus.circle").font(.system(size: 11, weight: .medium))
          .foregroundStyle(c.blocker == nil ? DS.color.textSecondary : DS.color.warning).frame(width: 16)
        Text(name).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1)
        Spacer(minLength: DS.space.xs)
        Text(summary(c)).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
      }
      .frame(height: Self.row)
      .dsTooltip(c.blocker)
    }
    ForEach(Array(Set(checks.flatMap { $0.preview?.blocker == nil ? ($0.preview?.notes ?? []) : [] })).sorted(), id: \.self) { n in note(n) }
  }

  private func summary(_ c: PostAtCheck) -> String {
    if let why = c.blocker { return "stays — " + (why.count > 44 ? String(why.prefix(42)) + "…" : why) }
    guard let p = c.preview else { return "" }
    if p.unchanged { return "already has this time" }
    return "\(p.platforms.count) platform\(p.platforms.count == 1 ? "" : "s")"
  }

  // MARK: Pieces

  private func line(_ p: Platform, text: String, dim: Bool, help: String?) -> some View {
    HStack(spacing: DS.space.xs) {
      Image(systemName: p.dsSymbol).font(.system(size: 11, weight: .medium)).foregroundStyle(dim ? DS.color.textTertiary : DS.color.textSecondary)
        .frame(width: 16)
      Text(p.dsxCompactName).font(DS.type.callout).foregroundStyle(dim ? DS.color.textTertiary : DS.color.text)
      Spacer(minLength: DS.space.xs)
      Text(text).font(DS.type.callout.monospacedDigit()).foregroundStyle(dim ? DS.color.textTertiary : DS.color.textSecondary).lineLimit(1)
    }
    .frame(height: Self.row)
    .contentShape(Rectangle())
    .dsTooltip(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(p.displayName): \(text)")
  }

  private func note(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
      Image(systemName: "info.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.color.textTertiary).frame(width: 16)
      Text(text).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 2)
  }

  /// The reason in place of the rows.
  private func blocked(_ why: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DS.space.xs) {
      Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.color.warning).frame(width: 16)
      Text(why).font(DS.type.callout).foregroundStyle(DS.color.text).fixedSize(horizontal: false, vertical: true)
    }
    .padding(DS.space.xs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.color.tint(.warning), in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Can't set this time: \(why)")
  }
}
