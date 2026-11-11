import DJQCore
import SwiftUI

/// Stage moves in the UI (Eric: "at any stage, bring a video back to its previous stage or move it forward a
/// stage") and Queue's "Back to Edit". The rules live in DJQCore (`BulkActions.back/forward/removeFromQueue`); this file
/// only names them, explains them and runs them through the shared bulk flow (confirmation + undo toast).
extension AppModel {
  func stage(_ v: Video) -> ClipStage? { ClipStage.of(v) }

  /// The Queue screen's clips: the upcoming plan, then the backlog — never a clip whose stage is Score or Edit.
  /// `queueList` takes every clip with an upcoming day, so a clip that fell back to Edit while it still sat on a day
  /// could show here with Edit's stage control ("Send to queue" on a Queue card, round 4 S1). Such a clip is in Edit
  /// only. A planned clip whose file went missing (no stage) stays in place and shows its problem.
  var queueClips: [Video] {
    queueList.filter { v in ClipStage.of(v).map { $0 >= .queue } ?? true }
  }

  /// Why `direction` can't move `v` (nil = it can). Core's data-free reasons (`StageWording.blocker`) plus the ones
  /// that need loaded posts (mirrors `BulkActions.blocker`; no DB read).
  func stageBlocker(_ v: Video, _ direction: StageDirection) -> String? {
    // Round 23: a stage move while its video is being made would throw the making away (Core refuses the result).
    if PhotoAudioUI.shared.busy == v.id { return PhotoAudioUI.busyReason }
    if let why = StageWording.blocker(v, direction) { return why }
    switch (ClipStage.of(v), direction) {
    case (.scheduled, .back): return removeFromQueueBlocker(v)
    case (.scheduled, .forward): return nextLivePost(v.id) == nil ? "Nothing left to mark posted" : nil
    default: return nil
    }
  }

  /// "Back to Score" · "Back to Edit" — always the clip's real neighbour (round 4 S1; no chevrons in the title, the
  /// icon carries it). From the clip's own stage, never from the screen it's shown on.
  func stageBackTitle(_ v: Video) -> String { StageWording.backTitle(v) }

  /// What back does, in words (tooltip).
  func stageBackHelp(_ v: Video) -> String { StageWording.backHelp(v) }

  static let removeFromQueueHelp = StageWording.backToEditHelp

  /// Why `v` can't leave the Calendar (Back to Edit, Unschedule): it already posted somewhere, or every platform
  /// finished. Mirrors `BulkActions.postedBlocker` from the loaded data.
  func removeFromQueueBlocker(_ v: Video) -> String? {
    if let p = (postsByVideo[v.id] ?? []).filter({ ($0.kind == .regular || $0.kind == .retry) && $0.state == .posted })
      .min(by: { ($0.postedAt ?? .distantFuture) < ($1.postedAt ?? .distantFuture) }) {
      return "Already posted on \(p.platform.displayName) — it can't leave the plan; skip or reset its posts in Posts"
    }
    if [.posted, .partial].contains(v.state) {
      return "Every platform is finished — nothing left in the plan to remove; repost or reset a post in Posts instead"
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

  /// "Score it" · "Send to Queue" · "Mark posted…" (from the clip's stage: a Queue card can never say "Send to Queue").
  func stageForwardTitle(_ v: Video) -> String { StageWording.forwardTitle(v) }

  func stageForwardHelp(_ v: Video) -> String { StageWording.forwardHelp(v) }

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

  /// "Thu 5 Nov · 6 platforms · pinned", or "… · set time 3:15 PM" (prefixed with the clip's name when several clips are
  /// involved).
  func unplannedLines(_ r: BulkResult) -> [String] {
    let all = (r.unplanned ?? [:]).sorted { $0.key < $1.key }
    return all.flatMap { id, items in
      items.map { i in
        let day = Fmt.day(dm.date(i.date), tz: tz, style: "EEE d MMM")
        let what = i.platforms.isEmpty ? "scheduled" : "\(i.platforms.count) platform\(i.platforms.count == 1 ? "" : "s")"
        let name = all.count > 1 ? (video(id).map(displayName) ?? id) + " — " : ""
        // A set time is always pinned: its own words say more.
        let mark = i.setTime.map { " · \(StageWording.setTimeMark($0, settings: settings))" } ?? (i.pinned ? " · pinned" : "")
        return name + day + " · " + what + mark
      }
    }
  }

  // MARK: Actions

  /// After a direct settings write (New clip defaults, a deleted template): a Queue clip that's no longer valid drops
  /// to Edit now instead of on the next engine tick (DJQCore `Revalidation`, states only — the plan is the engine's
  /// job). Nothing moves forward here: only Send to Queue does that.
  func revalidateStages() {
    let s = store
    Task.detached(priority: .userInitiated) {
      _ = try? Revalidation(store: s).run(adjustPlan: false)
      await MainActor.run { self.refresh() }
    }
  }

  /// Queue "Back to Edit" (F1, formerly "Remove from queue"): back to Edit, held there until "Send to Queue". Asks
  /// first (listing the days) when it would remove scheduled days, or for several clips.
  func removeFromQueue(_ ids: [String]) {
    if let why = removeFromQueueBlocker(ids) { show(why, error: true); return }
    let b = bulk
    let n = AppModel.pipelineClips(ids.count)
    requestBulk(BulkRequest(
      title: ids.count == 1 ? "Back to Edit?" : "Send \(n) back to Edit?", verb: "Back to Edit", ids: ids,
      changes: [.init(field: "Goes back to", value: "Edit · stays there until you send it to the Queue"),
                .init(field: "Plan", value: "Unposted days removed · posted ones stay · other clips keep their days")],
      alwaysConfirm: hasScheduledDays(ids), previewTitle: "Scheduled days removed",
      previewLines: { [weak self] r in self?.unplannedLines(r) ?? [] },
      doneText: { r in
        let n = r.changed.count
        let days = (r.unplanned ?? [:]).values.reduce(0) { $0 + $1.count }
        return (n == 1 ? "Back in Edit" : "\(n) back in Edit",
                "Held there until you send it to the Queue" + (days > 0 ? " · \(days) scheduled day\(days == 1 ? "" : "s") removed" : ""))
      }) { dry in try b.removeFromQueue(ids, dryRun: dry) })
  }

  /// One stage back for each clip. Asks first for several clips, for Back to Score (clears a score) and whenever
  /// scheduled days would go. `unschedule`: the Calendar's words for the same move.
  func stageBack(_ ids: [String], unschedule: Bool = false) {
    let vids = ids.compactMap(video)
    guard !vids.isEmpty else { return }
    // Unschedule never clears a score: back from Edit is Back to Score, a different move.
    if unschedule, vids.contains(where: { ![.queue, .scheduled].contains(ClipStage.of($0)) }) {
      show("It isn't in the Queue", error: true)
      return
    }
    if vids.count == 1, ClipStage.of(vids[0]) == .queue, !unschedule { removeFromQueue(ids); return }
    let b = bulk
    let one = vids.count == 1 ? vids[0] : nil
    let title: String
    if let v = one, ClipStage.of(v) == .edit {
      title = "Clear score \(v.score.map(String.init) ?? "") and send back to Score?"
    } else if unschedule || one.map({ ClipStage.of($0) == .scheduled }) == true {
      title = "Unschedule and send back to Edit?"
    } else {
      title = "Move \(AppModel.pipelineClips(vids.count)) back a stage?"
    }
    let anyScore = vids.contains { ClipStage.of($0) == .edit }
    requestBulk(BulkRequest(
      title: title, verb: unschedule ? "Unschedule" : one.map(stageBackTitle) ?? "Move back", ids: ids,
      changes: one == nil ? [.init(field: "Edit → Score", value: "Score cleared"),
                             .init(field: "Queue → Edit", value: "Held in Edit until sent to the Queue again"),
                             .init(field: "Scheduled → Edit", value: "Unposted days removed, held in Edit")] : [],
      alwaysConfirm: anyScore || hasScheduledDays(ids), previewTitle: one == nil ? "What happens" : "Scheduled days removed",
      previewLines: { [weak self] r in
        guard let self else { return [] }
        if one != nil { return self.unplannedLines(r) }
        return self.moveLines(r)
      },
      previewIcon: one == nil ? "arrow.uturn.backward" : "calendar",
      doneText: { [weak self] r in unschedule ? ("Unscheduled · back in Edit", nil) : self?.moveToast(r, back: true) ?? ("Done", nil) }) {
        dry in try b.back(ids, dryRun: dry)
      })
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
      changes: one == nil ? [.init(field: "Edit → Queue", value: "Default crop confirmed; clips still missing something stay in Edit")] : [],
      previewTitle: "What happens", previewLines: { [weak self] r in self?.moveLines(r) ?? [] }, previewIcon: "arrow.right",
      doneText: { [weak self] r in self?.moveToast(r, back: false) ?? ("Done", nil) }) { dry in try b.forward(ids, dryRun: dry) })
  }

  /// "Yayo x Johnny: Edit → Queue · Sent to the Queue" per moved clip, then the skipped ones with their reason.
  func moveLines(_ r: BulkResult) -> [String] {
    let moved = (r.moves ?? [:]).sorted { $0.key < $1.key }.map { id, m in
      "\(video(id).map(displayName) ?? id): \(StageWording.moveText(m.from, m.to)) · \(m.note)"
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
///
/// Round 21: an item in Edit, the Queue or on the Calendar also gets a clock button, "Post at a set time" (D12). It is
/// one more secondary action; on an item that has a time it reads "Set for Sat 14 Nov 3:15 PM — change".
struct StageControl: View {
  @Bindable var model: AppModel
  let video: Video
  var compact = false
  var size: DSButtonSize = .sm

  /// Clips in the Queue schedule themselves: there is no forward move to offer.
  private var hasForward: Bool { ClipStage.of(video) != .queue }

  /// Edit, Queue and Scheduled items can take a set time. Score comes first, and Posted is done.
  private var hasSetTime: Bool { [.edit, .queue, .scheduled].contains(ClipStage.of(video)) }

  var body: some View {
    let back = model.stageBlocker(video, .back)
    let fwd = model.stageBlocker(video, .forward)
    if compact {
      DSIconButton("chevron.left", tooltip: back == nil ? "\(model.stageBackTitle(video)) — \(model.stageBackHelp(video))" : model.stageBackTitle(video), size: .sm,
                   disabledReason: back) { model.stageBack([video.id]) }
      if hasForward {
        DSIconButton("chevron.right", tooltip: fwd == nil ? "\(model.stageForwardTitle(video)) — \(model.stageForwardHelp(video))" : model.stageForwardTitle(video), size: .sm,
                     disabledReason: fwd) { model.stageForward([video.id]) }
      }
      if hasSetTime { clock(.sm) }
    } else if size == .sm {
      HStack(spacing: 4) {
        moves(back, fwd)
        if hasSetTime { clock(size) }
      }
      .fixedSize()
    } else {
      // The Single view's side panel is a stack of labelled buttons, 280 pt wide: the set time gets its own line.
      VStack(alignment: .leading, spacing: DS.space.sm) {
        HStack(spacing: 4) { moves(back, fwd) }.fixedSize()
        if hasSetTime {
          let at = model.setTime(video.id)
          DSButton(at.map { StageWording.setFor($0, settings: model.settings) } ?? AppModel.postAtTitle, icon: at == nil ? "clock" : "clock.fill",
                   variant: .ghost, size: size, disabledReason: model.postAtBlocker(video),
                   tooltip: at == nil ? "Pick the exact day and minute it posts" : "Change the set time, or go back to the regular schedule") {
            model.askPostAt([video.id])
          }
          .background(ScriptAnchor("Post at \(video.id)"))
        }
      }
    }
  }

  @ViewBuilder private func moves(_ back: String?, _ fwd: String?) -> some View {
    DSButton(model.stageBackTitle(video), icon: "chevron.left", variant: .ghost, size: size, disabledReason: back,
             tooltip: model.stageBackHelp(video)) { model.stageBack([video.id]) }
    if hasForward {
      DSButton(model.stageForwardTitle(video), trailingIcon: "chevron.right", variant: .outline, size: size, disabledReason: fwd,
               tooltip: model.stageForwardHelp(video)) { model.stageForward([video.id]) }
    }
  }

  /// The clock: filled once the item has a set time, so it reads as "on" at a glance.
  private func clock(_ size: DSButtonSize) -> some View {
    let has = model.setTime(video.id) != nil
    return DSIconButton(has ? "clock.fill" : "clock", tooltip: model.postAtHelp(video), size: size,
                        disabledReason: model.postAtBlocker(video), isOn: has) { model.askPostAt([video.id]) }
      .background(ScriptAnchor("Post at \(video.id)"))
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
    // Native menu items can't show a tooltip: a disabled item carries its reason in the title.
    Button(menuTitle(many ? "Back a stage (\(targets.count))" : model.stageBackTitle(video), blocker: back), systemImage: "arrow.uturn.backward") {
      model.stageBack(targets)
    }
    .disabled(back != nil)
    if many || ClipStage.of(video) != .queue {
      Button(menuTitle(many ? "Forward a stage (\(targets.count))" : model.stageForwardTitle(video), blocker: fwd), systemImage: "arrow.forward") {
        model.stageForward(targets)
      }
      .disabled(fwd != nil)
    }
    // Round 21: the same door as the clock button, for one clip or the selection.
    let timeWhy = model.postAtBlocker(targets)
    Button(menuTitle(model.postAtMenuTitle(targets), blocker: timeWhy), systemImage: "clock") { model.askPostAt(targets) }
      .disabled(timeWhy != nil)
    if model.clearSetTimeBlocker(targets) == nil {
      Button(StageWording.useRegularSchedule, systemImage: "arrow.uturn.backward") { model.clearSetTimeAsking(targets) }
    }
  }

  private func menuTitle(_ title: String, blocker: String?) -> String {
    guard let b = blocker else { return title }
    return "\(title) — \(b.count > 60 ? String(b.prefix(57)) + "…" : b)"
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
