import DJQCore
import SwiftUI

/// Stage moves in the UI (Eric: "at any stage, bring a video back to its previous stage or move it forward a
/// stage") and "Remove from queue". The rules live in DJQCore (`BulkActions.back/forward/removeFromQueue`); this file
/// only names them, explains them and runs them through the shared bulk flow (confirmation + undo toast).
extension AppModel {
  func stage(_ v: Video) -> ClipStage? { ClipStage.of(v) }

  /// Why `direction` can't move `v` (nil = it can). Mirrors `BulkActions.blocker` from the loaded data (no DB read).
  func stageBlocker(_ v: Video, _ direction: StageDirection) -> String? {
    guard let st = ClipStage.of(v) else {
      if v.type != .short { return "Long-form clips are uploaded by hand — no stages" }
      if v.excluded { return "Excluded — include it first" }
      return "File missing — relink it first"
    }
    switch (st, direction) {
    case (.score, .back): return "Score is the first stage"
    case (.scheduled, .back): return removeFromQueueBlocker(v)
    case (.posted, .back): return "Posted — use Repost (next version) or Reset a wrongly marked post in Posts"
    case (.posted, .forward): return "Posted is the last stage"
    case (.scheduled, .forward):
      return nextLivePost(v.id) == nil ? "Nothing left to mark posted" : nil
    default: return nil
    }
  }

  /// "Back to Score" · "Remove from queue" · "Back to Queue" (button labels; no chevrons — the icon carries it).
  func stageBackTitle(_ v: Video) -> String {
    switch ClipStage.of(v) {
    case .edit: "Back to Score"
    case .queue: "Remove from queue"
    case .scheduled: "Back to Queue"
    default: "Back"
    }
  }

  /// What back does, in words (tooltip).
  func stageBackHelp(_ v: Video) -> String {
    switch ClipStage.of(v) {
    case .edit: "Clears its score (\(v.score.map(String.init) ?? "–")) and sends it back to Score"
    case .queue: Self.removeFromQueueHelp
    case .scheduled: "Unschedule: removes its unposted days from the plan; it stays ready in the Queue"
    default: stageBlocker(v, .back) ?? "Back a stage"
    }
  }

  static let removeFromQueueHelp = "Send back to Edit — unposted slots are removed"

  /// Why `v` can't leave the plan (Remove from queue / Back to Queue): it already posted somewhere, or every platform
  /// finished. Mirrors `BulkActions.postedBlocker` from the loaded data.
  func removeFromQueueBlocker(_ v: Video) -> String? {
    if let p = (postsByVideo[v.id] ?? []).filter({ ($0.kind == .regular || $0.kind == .retry) && $0.state == .posted })
      .min(by: { ($0.postedAt ?? .distantFuture) < ($1.postedAt ?? .distantFuture) }) {
      return "Already posted on \(p.platform.displayName) — it can't leave the plan; skip or reset its posts in Posts"
    }
    if [.posting, .posted, .partial].contains(v.state) {
      return "Already \(v.state.displayName.lowercased()) — it can't leave the plan; skip or reset its posts in Posts"
    }
    return nil
  }

  /// Remove-from-queue blocker for a menu acting on `targets`: the reason when NONE of them can go (one clip: its
  /// reason); nil when at least one can (the rest are skipped with their reason in the confirmation).
  func removeFromQueueBlocker(_ targets: [String]) -> String? {
    let reasons = targets.compactMap(video).map(removeFromQueueBlocker)
    guard !reasons.isEmpty, reasons.allSatisfy({ $0 != nil }) else { return nil }
    return targets.count == 1 ? reasons[0] : "Every selected clip already posted somewhere — they can't leave the plan"
  }

  /// "Score it" · "Send to queue" · "Schedule" · "Mark posted".
  func stageForwardTitle(_ v: Video) -> String {
    switch ClipStage.of(v) {
    case .score: "Score it"
    case .edit: "Send to queue"
    case .queue: "Schedule"
    case .scheduled: "Mark posted…"
    default: "Forward"
    }
  }

  func stageForwardHelp(_ v: Video) -> String {
    switch ClipStage.of(v) {
    case .score: "Opens Score to give it a score"
    case .edit: "Confirms the default crop where missing and sends it to the Queue; if something's still missing it stays here and says what"
    case .queue: "Pins it to the next open day of this or next week (a draft week still needs approval in Week)"
    case .scheduled: "Opens Mark posted for its next post (Today)"
    default: stageBlocker(v, .forward) ?? "Forward a stage"
    }
  }

  /// The clip's next post still in flight (Mark posted target).
  func nextLivePost(_ videoId: String) -> PlatformPost? {
    (postsByVideo[videoId] ?? []).filter { !$0.state.isTerminal }.min { $0.scheduledAt < $1.scheduledAt }
  }

  /// True when removing `ids` from the plan would take scheduled days (slots or in-flight posts) with it.
  func hasScheduledDays(_ ids: [String]) -> Bool {
    let set = Set(ids)
    return upcomingSlots.contains { set.contains($0.videoId) }
      || ids.contains { id in (postsByVideo[id] ?? []).contains { !$0.state.isTerminal } }
  }

  /// "Thu 5 Nov · 6 platforms · pinned" (prefixed with the clip's name when several clips are involved).
  func unplannedLines(_ r: BulkResult) -> [String] {
    let all = (r.unplanned ?? [:]).sorted { $0.key < $1.key }
    return all.flatMap { id, items in
      items.map { i in
        let day = Fmt.day(dm.date(i.date), tz: tz, style: "EEE d MMM")
        let what = i.platforms.isEmpty ? "proposed, not approved yet" : "\(i.platforms.count) platform\(i.platforms.count == 1 ? "" : "s")"
        let name = all.count > 1 ? (video(id).map(displayName) ?? id) + " — " : ""
        return name + day + " · " + what + (i.pinned ? " · pinned" : "")
      }
    }
  }

  // MARK: Actions

  /// Queue "Remove from queue" (F1): back to Edit, held there until "Send to queue". Asks first (listing the days)
  /// when it would remove scheduled days, or for several clips.
  func removeFromQueue(_ ids: [String]) {
    if let why = removeFromQueueBlocker(ids) { show(why, error: true); return }
    let b = bulk
    let n = AppModel.pipelineClips(ids.count)
    requestBulk(BulkRequest(
      title: ids.count == 1 ? "Remove from queue?" : "Remove \(n) from queue?", verb: "Remove from queue", ids: ids,
      changes: [.init(field: "Goes back to", value: "Edit · stays there until you Send to queue"),
                .init(field: "Plan", value: "Unposted days removed · posted ones stay · other clips keep their days")],
      alwaysConfirm: hasScheduledDays(ids), previewTitle: "Scheduled days removed",
      previewLines: { [weak self] r in self?.unplannedLines(r) ?? [] },
      doneText: { r in
        let n = r.changed.count
        let days = (r.unplanned ?? [:]).values.reduce(0) { $0 + $1.count }
        return (n == 1 ? "Removed from queue" : "Removed \(n) from queue",
                "Back in Edit" + (days > 0 ? " · \(days) scheduled day\(days == 1 ? "" : "s") removed" : ""))
      }) { dry in try b.removeFromQueue(ids, dryRun: dry) })
  }

  /// One stage back for each clip. Asks first for several clips, for Back to Score (clears a score) and whenever
  /// scheduled days would go.
  func stageBack(_ ids: [String]) {
    let vids = ids.compactMap(video)
    guard !vids.isEmpty else { return }
    if vids.count == 1, ClipStage.of(vids[0]) == .queue { removeFromQueue(ids); return }
    let b = bulk
    let one = vids.count == 1 ? vids[0] : nil
    let title: String
    if let v = one, ClipStage.of(v) == .edit {
      title = "Clear score \(v.score.map(String.init) ?? "") and send back to Score?"
    } else if let v = one, ClipStage.of(v) == .scheduled {
      title = "Unschedule and send back to Queue?"
    } else {
      title = "Move \(AppModel.pipelineClips(vids.count)) back a stage?"
    }
    let anyScore = vids.contains { ClipStage.of($0) == .edit }
    requestBulk(BulkRequest(
      title: title, verb: one.map(stageBackTitle) ?? "Move back", ids: ids,
      changes: one == nil ? [.init(field: "Edit → Score", value: "Score cleared"),
                             .init(field: "Queue → Edit", value: "Removed from queue, held in Edit"),
                             .init(field: "Scheduled → Queue", value: "Unposted days removed, stays ready")] : [],
      alwaysConfirm: anyScore || hasScheduledDays(ids), previewTitle: one == nil ? "What happens" : "Scheduled days removed",
      previewLines: { [weak self] r in
        guard let self else { return [] }
        if one != nil { return self.unplannedLines(r) }
        return self.moveLines(r)
      },
      previewIcon: one == nil ? "arrow.uturn.backward" : "calendar",
      doneText: { [weak self] r in self?.moveToast(r, back: true) ?? ("Done", nil) }) { dry in try b.back(ids, dryRun: dry) })
  }

  /// One stage forward. Score → opens Score; Scheduled → Mark posted for the next post; Edit/Queue → BulkActions.
  func stageForward(_ ids: [String]) {
    let vids = ids.compactMap(video)
    guard !vids.isEmpty else { return }
    if vids.count == 1, let v = vids.first {
      switch ClipStage.of(v) {
      case .score:
        editor = nil
        screen = .score
        selection[.score] = [v.id]
        show("Give it a score on Score")
        return
      case .scheduled:
        if let p = nextLivePost(v.id) { markPostedTarget = p } else { show(stageBlocker(v, .forward) ?? "Nothing to mark posted") }
        return
      default: break
      }
    }
    let b = bulk
    let one = vids.count == 1 ? vids[0] : nil
    requestBulk(BulkRequest(
      title: one.map { "\(stageForwardTitle($0))?" } ?? "Move \(AppModel.pipelineClips(vids.count)) forward a stage?",
      verb: one.map(stageForwardTitle) ?? "Move forward", ids: ids,
      changes: one == nil ? [.init(field: "Edit → Queue", value: "Default crop confirmed; clips still missing something stay in Edit"),
                             .init(field: "Queue → Scheduled", value: "Next open day this or next week, pinned")] : [],
      previewTitle: "What happens", previewLines: { [weak self] r in self?.moveLines(r) ?? [] }, previewIcon: "arrow.right",
      doneText: { [weak self] r in self?.moveToast(r, back: false) ?? ("Done", nil) }) { dry in try b.forward(ids, dryRun: dry) })
  }

  /// "Yayo x Johnny: Edit → Queue · Ready — in the queue" per moved clip, then the skipped ones with their reason.
  func moveLines(_ r: BulkResult) -> [String] {
    let moved = (r.moves ?? [:]).sorted { $0.key < $1.key }.map { id, m in
      "\(video(id).map(displayName) ?? id): \(m.from.displayName) → \(m.to.displayName) · \(m.note)"
    }
    let skipped = r.skipped.sorted { $0.key < $1.key }.map { id, why in "\(video(id).map(displayName) ?? id): stays — \(why)" }
    return moved + skipped
  }

  func moveToast(_ r: BulkResult, back: Bool) -> (String, String?) {
    let moves = Array((r.moves ?? [:]).values)
    if moves.count == 1, let m = moves.first {
      let head = m.note.components(separatedBy: " · ").first ?? m.note
      return (head, nil)
    }
    let stuck = moves.filter { $0.from == $0.to }.count
    return ("Moved \(moves.count - stuck) \(back ? "back" : "forward")",
            stuck > 0 ? "\(stuck) still in \(moves.first { $0.from == $0.to }?.to.displayName ?? "Edit") — see each card" : nil)
  }
}

/// The per-clip stage control: "‹ Back to <stage>" (ghost) and "<Next action> ›" (outlined, never a second
/// primary), each tooltipped with exactly what happens and disabled with the reason when impossible.
/// `compact` = icon-only round buttons (grid tiles, tight rows).
struct StageControl: View {
  @Bindable var model: AppModel
  let video: Video
  var compact = false
  var size: DSButtonSize = .sm

  var body: some View {
    let back = model.stageBlocker(video, .back)
    let fwd = model.stageBlocker(video, .forward)
    if compact {
      DSIconButton("chevron.left", tooltip: back ?? "\(model.stageBackTitle(video)) — \(model.stageBackHelp(video))", size: .sm,
                   disabledReason: back) { model.stageBack([video.id]) }
      DSIconButton("chevron.right", tooltip: fwd ?? "\(model.stageForwardTitle(video)) — \(model.stageForwardHelp(video))", size: .sm,
                   disabledReason: fwd) { model.stageForward([video.id]) }
    } else {
      HStack(spacing: 4) {
        DSButton(model.stageBackTitle(video), icon: "chevron.left", variant: .ghost, size: size, disabledReason: back,
                 tooltip: model.stageBackHelp(video)) { model.stageBack([video.id]) }
        DSButton(model.stageForwardTitle(video), trailingIcon: "chevron.right", variant: .outline, size: size, disabledReason: fwd,
                 tooltip: model.stageForwardHelp(video)) { model.stageForward([video.id]) }
      }
      .fixedSize()
    }
  }
}

/// Menu items for the same moves (⋯ / right-click). Acts on `targets` (the selection when the clip is in it).
struct StageMenuItems: View {
  @Bindable var model: AppModel
  let video: Video
  let targets: [String]

  var body: some View {
    let many = targets.count > 1
    let back = many ? nil : model.stageBlocker(video, .back)
    let fwd = many ? nil : model.stageBlocker(video, .forward)
    Button(many ? "Back a stage (\(targets.count))" : model.stageBackTitle(video), systemImage: "arrow.uturn.backward") {
      model.stageBack(targets)
    }
    .disabled(back != nil)
    .help(back ?? (many ? "Each clip goes back one stage" : model.stageBackHelp(video)))
    Button(many ? "Forward a stage (\(targets.count))" : model.stageForwardTitle(video), systemImage: "arrow.forward") {
      model.stageForward(targets)
    }
    .disabled(fwd != nil)
    .help(fwd ?? (many ? "Each clip moves forward one stage" : model.stageForwardHelp(video)))
  }
}

/// The editor header's stage control (the clip being edited; hidden for clips without a stage).
struct EditorStageControl: View {
  @Bindable var model: AppModel
  let videoId: String

  var body: some View {
    if let v = model.video(videoId), ClipStage.of(v) != nil {
      StageControl(model: model, video: v)
    }
  }
}
