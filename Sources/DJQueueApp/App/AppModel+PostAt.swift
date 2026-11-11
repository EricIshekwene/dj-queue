import DJQCore
import Foundation

/// Round 21, "Post at a set time" (DECISIONS-R21.md D12–D14). Every entry point (stage control, menus, Calendar, ⌘K)
/// calls `askPostAt`; the dialog (`Shared/PostAtDialog.swift`) and the live check call `postAt` and `clearSetTime`.
/// The rules live in DJQCore (`BulkActions.postAt`, `clearExact`, `postAtPreview`); this file names them and runs them.
struct PostAtRequest: Identifiable, Equatable {
  let id = UUID()
  /// The items to give a time (one, or a selection).
  var videoIds: [String]
}

extension AppModel {
  static let postAtTitle = "Post at a set time"
  static let postAtHelp = "Post at a set time — pick the exact day and minute"

  /// Opens the dialog for these items. One item that can't take a time says why instead.
  func askPostAt(_ ids: [String]) {
    let ids = ids.filter { video($0) != nil }
    guard !ids.isEmpty else { return }
    if let why = postAtBlocker(ids) { show(why, error: true); return }
    postAtRequest = PostAtRequest(videoIds: ids)
  }

  /// The item's set-time slot (nil = it follows the regular schedule), from the loaded plan.
  func setTimeSlot(_ videoId: String) -> PlanSlot? {
    if let s = nextSlotByVideo[videoId], s.isExact { return s }
    return calendarData.setTimes[videoId]
  }

  /// The item's set time, nil on the regular schedule.
  func setTime(_ videoId: String) -> Date? { setTimeSlot(videoId)?.exactAt }

  /// "Sat 14 Nov 3:15 PM" in the Settings time zone: the one way a set time is written.
  func setTimeText(_ at: Date) -> String { StageWording.dayTime(at, settings: settings) }

  /// The clock button's tooltip: what it does, or the time the item has.
  func postAtHelp(_ v: Video) -> String {
    setTime(v.id).map { "\(StageWording.setFor($0, settings: settings)) — change" } ?? Self.postAtHelp
  }

  /// "Post at a set time…" / "Change set time…" for a menu acting on `targets`.
  func postAtMenuTitle(_ targets: [String]) -> String {
    let many = targets.count > 1 ? " (\(targets.count))" : ""
    return (targets.contains { setTime($0) != nil } ? "Change set time…" : "Post at a set time…") + many
  }

  /// Why `v` can't take a set time at all (nil = the dialog can open). What is still missing in Edit isn't a reason
  /// here: the dialog says it, in Send to Queue's words.
  func postAtBlocker(_ v: Video) -> String? {
    guard let stage = ClipStage.of(v) else { return StageWording.noStageReason(v) }
    if v.missing, stage == .edit { return StageWording.fileMissing }
    if let p = (postsByVideo[v.id] ?? []).filter({ ($0.kind == .regular || $0.kind == .retry) && $0.state == .posted })
      .min(by: { $0.platform < $1.platform }) {
      return "Already posted on \(p.platform.displayName) — it can't take a set time"
    }
    switch stage {
    case .score: return "Give it a score on Score first"
    case .posted: return "Every platform is finished — it can't take a set time"
    default: return nil
    }
  }

  /// The blocker for a menu acting on `targets`: the reason when NONE of them can take a time (one item: its reason).
  func postAtBlocker(_ targets: [String]) -> String? {
    let reasons = targets.compactMap(video).map(postAtBlocker)
    guard !reasons.isEmpty, reasons.allSatisfy({ $0 != nil }) else { return nil }
    return targets.count == 1 ? reasons[0] : "None of the selected items can take a set time"
  }

  /// Why "Use the regular schedule" isn't offered for `targets` (nil = it is): none of them has a set time.
  func clearSetTimeBlocker(_ targets: [String]) -> String? {
    targets.contains { setTime($0) != nil } ? nil : StageWording.noSetTime
  }

  /// "New York time": the Settings time zone in words.
  var timeZoneText: String {
    let city = settings.timeZone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
    return "\(city ?? settings.tz.identifier) time"
  }

  /// Sets `at` as the time every platform of each item goes out (`BulkActions.postAt`, off the main thread). For an item
  /// still in Edit this is Eric's Send to Queue (D13). Done: a toast with the move note and Undo, and nil. Not done: the
  /// reason comes back for the dialog to show, and nothing changed.
  @discardableResult
  func postAt(ids: [String], at: Date) async -> String? {
    splitEditorSession()
    let b = bulk
    let out: Result<BulkResult, Error> = await Task.detached(priority: .userInitiated) { Result { try b.postAt(ids, at: at) } }.value
    switch out {
    case .failure(let e):
      refresh()
      return e.localizedDescription
    case .success(let r):
      let when = StageWording.setFor(at, settings: settings)
      guard !r.changed.isEmpty else {
        refresh()
        if let why = skippedReason(r) { return why }
        show("Already \(when.prefix(1).lowercased() + when.dropFirst())")
        return nil
      }
      let n = r.changed.count
      let label = n == 1 ? (r.moves?[r.changed[0]]?.note ?? when) : "\(n) items \(when.prefix(1).lowercased() + when.dropFirst())"
      journaledToast(r, label: label, detail: skippedDetail(r))
      return nil
    }
  }

  /// "Use the regular schedule" (`BulkActions.clearExact`): the set time goes and the item is back in the Queue, where
  /// the next scheduling pass gives it a day. A toast with Undo and nil, or the reason.
  @discardableResult
  func clearSetTime(ids: [String]) async -> String? {
    splitEditorSession()
    let b = bulk
    let out: Result<BulkResult, Error> = await Task.detached(priority: .userInitiated) { Result { try b.clearExact(ids) } }.value
    switch out {
    case .failure(let e):
      refresh()
      return e.localizedDescription
    case .success(let r):
      guard !r.changed.isEmpty else {
        refresh()
        return skippedReason(r) ?? StageWording.noSetTime
      }
      let n = r.changed.count
      let note = r.moves?[r.changed[0]]?.note ?? StageWording.regularSchedule
      let parts = note.components(separatedBy: " · ")
      let label = n == 1 ? parts[0] : "\(n) items back on the regular schedule"
      let more = n == 1 ? Array(parts.dropFirst()) : []
      journaledToast(r, label: label, detail: (more + [skippedDetail(r)].compactMap { $0 }).joined(separator: " · "))
      return nil
    }
  }

  /// "Use the regular schedule" from a menu: there is no dialog to hold a refusal, so it shows as a toast.
  func clearSetTimeAsking(_ ids: [String]) {
    let timed = ids.filter { setTime($0) != nil }
    guard !timed.isEmpty else { show(StageWording.noSetTime, error: true); return }
    Task { if let why = await clearSetTime(ids: timed) { show(why, error: true) } }
  }

  /// One item left as it was: its reason. Several: how many, and the first reason.
  private func skippedReason(_ r: BulkResult) -> String? {
    guard let first = r.skipped.sorted(by: { $0.key < $1.key }).first else { return nil }
    if r.skipped.count == 1, r.videoIds.count == 1 { return first.value }
    let name = video(first.key).map(displayName) ?? "One item"
    return r.skipped.count == 1 ? "“\(name)” stays as it is: \(first.value)" : "\(r.skipped.count) items stay as they are. “\(name)”: \(first.value)"
  }

  private func skippedDetail(_ r: BulkResult) -> String? {
    r.skipped.isEmpty ? nil : skippedReason(r)
  }

  /// A journaled batch landed: reload, into the undo history, and the toast with Undo (`didJournal` with a detail line).
  private func journaledToast(_ r: BulkResult, label: String, detail: String?) {
    ChangeSignal.post()
    refresh()
    let detail = detail.flatMap { $0.isEmpty ? nil : $0 }
    guard let b = r.batchId else { show(DSToastModel(message: label, detail: detail, duration: 4)); return }
    undoHistory.push(b, label: label)
    show(DSToastModel(message: label, detail: detail, tone: .success, actionTitle: "Undo",
                      action: { [weak self] in self?.undo(batch: b) }, duration: 6))
  }
}

/// A clock time as Eric types it: "7pm", "7:30 pm", "19:00", "730p", "noon". Forgiving, and never a guess: what it can't
/// read is nil and the field says so.
enum PostAtClock {
  /// Minutes after midnight, or nil.
  static func minutes(_ raw: String) -> Int? {
    var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
    if s == "noon" || s == "midday" { return 12 * 60 }
    if s == "midnight" { return 0 }
    var half: String?
    for (suffix, name) in [("a.m.", "am"), ("p.m.", "pm"), ("am", "am"), ("pm", "pm"), ("a", "am"), ("p", "pm")] where s.hasSuffix(suffix) {
      half = name
      s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
      break
    }
    let parts = s.split(whereSeparator: { ":. ".contains($0) }).map(String.init)
    guard !parts.isEmpty, parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
    var h: Int, m: Int
    if parts.count == 2 {
      guard parts[1].count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
      (h, m) = (a, b)
    } else if parts[0].count <= 2 {
      guard let a = Int(parts[0]) else { return nil }
      (h, m) = (a, 0)
    } else if parts[0].count <= 4 {  // "730", "1915"
      guard let a = Int(parts[0].dropLast(2)), let b = Int(parts[0].suffix(2)) else { return nil }
      (h, m) = (a, b)
    } else {
      return nil
    }
    guard m < 60 else { return nil }
    if let half {
      guard (1...12).contains(h) else { return nil }
      h = h % 12 + (half == "pm" ? 12 : 0)
    }
    guard h < 24 else { return nil }
    return h * 60 + m
  }

  /// "3:15 PM".
  static func text(_ minutes: Int) -> String {
    let h = minutes / 60
    return "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", minutes % 60)) \(h < 12 ? "AM" : "PM")"
  }
}
