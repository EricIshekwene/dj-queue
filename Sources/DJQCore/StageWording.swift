import Foundation

// Round 4 S1 "Stage = readiness": the ONE place that names stages, a stage's real neighbours (the stage control's
// back/forward labels and what they do) and why a clip is in Edit (reason chips). The app and `djq` both read it,
// so the words never drift apart. There are no "Ready" / "Needs edit" / "Unready" labels: Edit = not ready yet,
// Queue = ready (and only ever ready clips), Scheduled = has a day on the Calendar (a status, not a step: round 13).

// MARK: - Stage control (back / forward)

extension ClipStage {
  /// The stage the back control goes to (Edit → Score, Queue → Edit, Scheduled → Edit: a clip put back in the Queue
  /// would only get a day again). nil: no back move.
  public var backTarget: ClipStage? {
    switch self {
    case .edit: .score
    case .queue, .scheduled: .edit
    case .score, .posted: nil
    }
  }

  /// The stage the forward control goes to (Score → Edit, Edit → Queue, Scheduled → Posted). nil: no forward move
  /// (Queue clips schedule themselves).
  public var forwardTarget: ClipStage? { self == .queue ? nil : next }

  /// Back control label, naming the real neighbour: "Back to Score" · "Back to Edit".
  /// nil for Score (first stage) and Posted (Repost / Reset instead).
  public var backTitle: String? { backTarget.map { "Back to \($0.displayName)" } }

  /// Forward control label: "Score it" · "Send to Queue" · "Mark posted…". nil for the Queue and Posted.
  public var forwardTitle: String? {
    switch self {
    case .score: "Score it"
    case .edit: "Send to Queue"
    case .scheduled: "Mark posted…"
    case .queue, .posted: nil
    }
  }

  /// What back does (tooltip). `score` is the clip's score (Edit → Score clears it).
  public func backHelp(score: Int?) -> String? {
    switch self {
    case .edit: "Clears its score (\(score.map(String.init) ?? "–")) and sends it back to Score"
    case .queue: StageWording.backToEditHelp
    case .scheduled: StageWording.unscheduleHelp
    case .score, .posted: nil
    }
  }

  /// What forward does (tooltip).
  public var forwardHelp: String? {
    switch self {
    case .score: "Opens Score to give it a score"
    case .edit: "Confirms the default crop where missing and sends it to the Queue; if something's still missing it stays in Edit and says what"
    case .scheduled: "Opens Mark posted for its next post (Calendar)"
    case .queue, .posted: nil
    }
  }
}

/// Stage words for one clip (the per-clip stage control, menus, `djq stage`). Data-free: blockers that need posts
/// (Scheduled → back once something posted, Scheduled → forward with nothing left to mark) are added by the caller
/// (`BulkActions.blocker` reads the DB; the app reads its loaded posts).
public enum StageWording {
  /// Queue → Edit (formerly "Remove from queue"): the clip is held in Edit until it is sent to the Queue again.
  public static let backToEditHelp = "Sends it back to Edit and keeps it there until you send it to the Queue again; its unposted days are removed"
  /// Scheduled → Edit: same move, seen from the Calendar.
  public static let unscheduleHelp = "Takes it off the calendar and holds it in Edit until you send it to the Queue again"
  /// Why a swap was refused: the other clip would land on a slot inside the lead.
  public static let todayTooSoon = "Today's slot is too soon"
  /// Why the Queue has no forward move.
  public static let queueSchedulesItself = "Clips in the Queue schedule themselves"

  /// Back label for `v`: "Back to Score" / "Back to Edit"; "Back" when it has no back move.
  public static func backTitle(_ v: Video) -> String {
    if v.isPhoto, ClipStage.of(v) == .edit { return "Back" }  // a photo post has no Score stage to go back to
    return ClipStage.of(v)?.backTitle ?? "Back"
  }

  /// Forward label for `v`: "Score it" / "Send to Queue" / "Mark posted…"; "Forward" otherwise.
  public static func forwardTitle(_ v: Video) -> String { ClipStage.of(v)?.forwardTitle ?? "Forward" }

  /// Back tooltip for `v` (falls back to the blocker, then "Back a stage").
  public static func backHelp(_ v: Video) -> String {
    if v.isPhoto, ClipStage.of(v) == .edit { return PhotoRules.noScoreStage }
    return ClipStage.of(v)?.backHelp(score: v.score) ?? blocker(v, .back) ?? "Back a stage"
  }

  /// Forward tooltip for `v` (falls back to the blocker, then "Forward a stage").
  public static func forwardHelp(_ v: Video) -> String {
    ClipStage.of(v)?.forwardHelp ?? blocker(v, .forward) ?? "Forward a stage"
  }

  /// Why `direction` can't move `v`, from the clip alone (nil = no data-free reason; the caller may still add one).
  /// Covers: no stage (long-form / excluded / file missing), a missing file in Edit, Score back, Queue forward,
  /// Posted back/forward.
  public static func blocker(_ v: Video, _ direction: StageDirection) -> String? {
    guard let st = ClipStage.of(v) else { return noStageReason(v) }
    if v.missing, st == .edit { return fileMissing }
    switch (st, direction) {
    case (.edit, .back) where v.isPhoto: return PhotoRules.noScoreStage
    case (.score, .back): return "Score is the first stage"
    case (.queue, .forward): return queueSchedulesItself
    case (.posted, .back): return "Posted — use Repost (next version) or Reset a wrongly marked post in Posts"
    case (.posted, .forward): return "Posted is the last stage"
    default: return nil
    }
  }

  public static let fileMissing = "File missing — relink it first"

  /// Why a clip has no stage at all.
  public static func noStageReason(_ v: Video) -> String {
    if v.type != .short { return "Long-form clips are uploaded by hand — no stages" }
    if v.excluded { return "Excluded — include it first" }
    if v.missing { return fileMissing }
    return "No stage"
  }

  /// "Edit → Queue" style arrow text for a move, using stage names.
  public static func moveText(_ from: ClipStage, _ to: ClipStage) -> String { "\(from.displayName) → \(to.displayName)" }

  /// The `StageMove.note` when a forward move from Edit lands in the Queue.
  public static let sentToQueue = "Sent to the Queue"
  /// The `StageMove.note` prefix when a clip stays in Edit: "Still in Edit: No crop; No text".
  public static func stillInEdit(_ issues: [ValidationIssue]) -> String {
    "Still in Edit: " + issues.map(\.message).joined(separator: "; ")
  }
  /// The `StageMove.note` for Queue → Edit.
  public static let backInEdit = "Back in Edit — held there until you send it to the Queue"

  /// Event logged when the engine moves an invalid Queue clip to Edit: "Moved to Edit: No crop · Too long for X".
  public static func movedToEdit(_ issues: [ValidationIssue]) -> String {
    "Moved to Edit: " + reasonsText(issues)
  }

  /// "Queue running low" (the notification, Doctor and the Calendar's card).
  public static let queueLowTitle = "Queue running low"

  /// "Scheduled through Sat 7 Nov" · "Nothing scheduled". `day` is `Runway.scheduledThrough`.
  public static func scheduledThrough(_ day: String?, settings s: Settings) -> String {
    day.map { "Scheduled through \(BulkActions.day($0, DayMath(settings: s), s))" } ?? "Nothing scheduled"
  }

  /// "Scheduled through Sat 7 Nov. Send more clips from Edit."
  public static func queueLowBody(_ day: String?, settings s: Settings) -> String {
    "\(scheduledThrough(day, settings: s)). Send more clips from Edit."
  }

  /// The event of a clip the scheduler gave a day. `day` is already formatted ("Tue 10 Nov").
  public static func scheduledFor(_ day: String) -> String { "Scheduled for \(day)" }

  /// Event logged instead of "Moved to Edit" for a clip pinned to a day: it stays on that day and can't post until
  /// fixed. `day` is already formatted ("Tue 10 Nov").
  public static func cantPost(on day: String, _ issues: [ValidationIssue]) -> String {
    "Can't post on \(day): " + reasonsText(issues)
  }

  /// "No crop · Too long for X" (chip texts in chip order, de-duplicated).
  public static func reasonsText(_ issues: [ValidationIssue]) -> String {
    var seen = Set<String>()
    return issues.sorted { $0.kind.chipOrder < $1.kind.chipOrder }.map(\.chipText).filter { seen.insert($0).inserted }
      .joined(separator: " · ")
  }
}

// MARK: - Why a clip is in Edit (reason chips)

extension ValidationIssue.Kind {
  /// Bucket label for the Edit page's reason chips (no platform), e.g. "No crop", "Too long", "File missing".
  public var chipLabel: String {
    switch self {
    case .noCrop: "No crop"
    case .noText: "No text"
    case .noCaption: "No caption"
    case .noTitle: "No title"
    case .tooLong: "Too long"
    case .tooLarge: "Too large"
    case .captionTooLong: "Caption too long"
    case .titleTooLong: "Title too long"
    case .corrupt: "Edit unreadable"
    case .missingFile: "File missing"
    case .heldInEdit: "Sent back from Queue"
    case .noPhotos: "No photos"
    case .photoShape: "Photo shape"
    }
  }

  /// What the chip means and what fixes it (tooltip; TOOLTIPS-AUDIT wording: "Still needed before it can go to
  /// the Queue" for missing pieces, "Blocks posting" for hard limits).
  public var chipHelp: String {
    switch self {
    case .noCrop: "Still needed before it can go to the Queue: confirm the crop in the editor"
    case .noText: "Still needed before it can go to the Queue: add text, or choose No text"
    case .noCaption: "Still needed before it can go to the Queue: write a caption or choose a template that exists"
    case .noTitle: "Still needed before it can go to the Queue: give it a title"
    case .tooLong: "Blocks posting: longer than a platform allows — trim it or skip that platform"
    case .tooLarge: "Blocks posting: the file is larger than a platform allows"
    case .captionTooLong: "Blocks posting: the caption is longer than a platform allows — shorten it or drop hashtags there"
    case .titleTooLong: "Blocks posting: the YouTube title is longer than YouTube allows"
    case .corrupt: "The saved edit can't be read — see Doctor"
    case .missingFile: "The clip file is gone — relink it in Health"
    case .heldInEdit: "You sent it back from the Queue — send it to the Queue again when it's done"
    case .noPhotos: "Still needed before it can go to the Queue: add a photo in the editor"
    case .photoShape: "Blocks posting: a platform doesn't take photos in this shape — pick another shape or turn that platform off for this post"
    }
  }

  /// Missing pieces (warning) vs hard blocks (danger) — the card colours them differently.
  public var isBlock: Bool {
    switch self {
    case .tooLong, .tooLarge, .captionTooLong, .titleTooLong, .corrupt, .missingFile, .photoShape: true
    case .noCrop, .noText, .noCaption, .noTitle, .heldInEdit, .noPhotos: false
    }
  }

  /// Chip order: sent back first, then missing pieces, then hard blocks.
  public var chipOrder: Int {
    switch self {
    case .heldInEdit: -1
    case .noPhotos: 0
    case .noCrop: 1
    case .noText: 2
    case .noCaption: 3
    case .noTitle: 4
    case .photoShape: 5
    case .tooLong: 6
    case .captionTooLong: 7
    case .tooLarge: 8
    case .titleTooLong: 9
    case .corrupt: 10
    case .missingFile: 11
    }
  }

  /// Every kind in chip order.
  public static var inChipOrder: [ValidationIssue.Kind] {
    [.heldInEdit, .noPhotos, .noCrop, .noText, .noCaption, .noTitle, .photoShape, .tooLong, .captionTooLong, .tooLarge, .titleTooLong, .corrupt,
     .missingFile]
  }
}

extension ValidationIssue {
  /// Card chip text, with the platform where it matters: "No crop" · "Too long for X" · "Caption too long for
  /// Threads" · "YouTube title too long" · "File missing" · "Sent back from Queue".
  public var chipText: String {
    let p = platform?.displayName
    switch kind {
    case .tooLong: return p.map { "Too long for \($0)" } ?? "Too long"
    case .tooLarge: return p.map { "Too large for \($0)" } ?? "Too large"
    case .captionTooLong: return p.map { "Caption too long for \($0)" } ?? "Caption too long"
    case .titleTooLong: return "YouTube title too long"
    case .photoShape: return p.map { "Wrong shape for \($0)" } ?? "Wrong shape"
    default: return kind.chipLabel
    }
  }

  /// Numbers behind a length chip: "0:45 > 0:30" (duration) / "2301/2200" (caption, title). nil otherwise.
  public var chipDetail: String? {
    guard let c = count, let l = limit else { return nil }
    switch kind {
    case .tooLong: return "\(Validation.fmt(c)) > \(Validation.fmt(l))"
    case .captionTooLong, .titleTooLong: return "\(Int(c))/\(Int(l))"
    default: return nil
    }
  }

  /// The distinct reason buckets of one clip, in chip order (what the Edit page counts per chip).
  public static func buckets(_ issues: [ValidationIssue]) -> [Kind] {
    Kind.inChipOrder.filter { k in issues.contains { $0.kind == k } }
  }

  /// Clips per reason bucket across a list (each clip counts once per bucket), in chip order, zero buckets dropped.
  public static func bucketCounts(_ issuesByClip: [String: [ValidationIssue]]) -> [(kind: Kind, count: Int)] {
    var counts: [Kind: Int] = [:]
    for list in issuesByClip.values { for k in buckets(list) { counts[k, default: 0] += 1 } }
    return Kind.inChipOrder.compactMap { k in counts[k].map { (k, $0) } }
  }
}
