import Foundation

// Round 4 S1 "Stage = readiness": the ONE place that names stages, a stage's real neighbours (the stage control's
// back/forward labels and what they do) and why a clip is in Edit (reason chips). The app and `djq` both read it,
// so the words never drift apart. There are no "Ready" / "Needs edit" / "Unready" labels: Edit = not ready yet,
// Queue = ready (and only ever ready clips), Scheduled = in an approved week.

// MARK: - Stage control (back / forward)

extension ClipStage {
  /// The stage the back control goes to (Edit → Score, Queue → Edit, Scheduled → Queue). nil: no back move.
  public var backTarget: ClipStage? {
    switch self {
    case .edit, .queue, .scheduled: previous
    case .score, .posted: nil
    }
  }

  /// The stage the forward control goes to (Score → Edit, Edit → Queue, Queue → Scheduled, Scheduled → Posted).
  public var forwardTarget: ClipStage? { next }

  /// Back control label, naming the real neighbour: "Back to Score" · "Back to Edit" · "Back to Queue".
  /// nil for Score (first stage) and Posted (Repost / Reset instead).
  public var backTitle: String? { backTarget.map { "Back to \($0.displayName)" } }

  /// Forward control label: "Score it" · "Send to Queue" · "Schedule" · "Mark posted…". nil for Posted.
  public var forwardTitle: String? {
    switch self {
    case .score: "Score it"
    case .edit: "Send to Queue"
    case .queue: "Schedule"
    case .scheduled: "Mark posted…"
    case .posted: nil
    }
  }

  /// What back does (tooltip). `score` is the clip's score (Edit → Score clears it).
  public func backHelp(score: Int?) -> String? {
    switch self {
    case .edit: "Clears its score (\(score.map(String.init) ?? "–")) and sends it back to Score"
    case .queue: StageWording.backToEditHelp
    case .scheduled: "Unschedule: removes its unposted days from the plan; it goes back to the Queue"
    case .score, .posted: nil
    }
  }

  /// What forward does (tooltip).
  public var forwardHelp: String? {
    switch self {
    case .score: "Opens Score to give it a score"
    case .edit: "Confirms the default crop where missing and sends it to the Queue; if something's still missing it stays in Edit and says what"
    case .queue: "Pins it to the next open day of this or next week (a draft week still needs approval in Week)"
    case .scheduled: "Opens Mark posted for its next post (Today)"
    case .posted: nil
    }
  }
}

/// Stage words for one clip (the per-clip stage control, menus, `djq stage`). Data-free: blockers that need posts
/// (Scheduled → back once something posted, Scheduled → forward with nothing left to mark) are added by the caller
/// (`BulkActions.blocker` reads the DB; the app reads its loaded posts).
public enum StageWording {
  /// Queue → Edit (formerly "Remove from queue"): the clip is held in Edit until it is sent to the Queue again.
  public static let backToEditHelp = "Sends it back to Edit and keeps it there until you send it to the Queue again; its unposted days are removed"

  /// Back label for `v`: "Back to Score" / "Back to Edit" / "Back to Queue"; "Back" when it has no back move.
  public static func backTitle(_ v: Video) -> String { ClipStage.of(v)?.backTitle ?? "Back" }

  /// Forward label for `v`: "Score it" / "Send to Queue" / "Schedule" / "Mark posted…"; "Forward" otherwise.
  public static func forwardTitle(_ v: Video) -> String { ClipStage.of(v)?.forwardTitle ?? "Forward" }

  /// Back tooltip for `v` (falls back to the blocker, then "Back a stage").
  public static func backHelp(_ v: Video) -> String {
    ClipStage.of(v)?.backHelp(score: v.score) ?? blocker(v, .back) ?? "Back a stage"
  }

  /// Forward tooltip for `v` (falls back to the blocker, then "Forward a stage").
  public static func forwardHelp(_ v: Video) -> String {
    ClipStage.of(v)?.forwardHelp ?? blocker(v, .forward) ?? "Forward a stage"
  }

  /// Why `direction` can't move `v`, from the clip alone (nil = no data-free reason; the caller may still add one).
  /// Covers: no stage (long-form / excluded / file missing), a missing file in Edit, Score back, Posted back/forward.
  public static func blocker(_ v: Video, _ direction: StageDirection) -> String? {
    guard let st = ClipStage.of(v) else { return noStageReason(v) }
    if v.missing, st == .edit { return fileMissing }
    switch (st, direction) {
    case (.score, .back): return "Score is the first stage"
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
    }
  }

  /// Missing pieces (warning) vs hard blocks (danger) — the card colours them differently.
  public var isBlock: Bool {
    switch self {
    case .tooLong, .tooLarge, .captionTooLong, .titleTooLong, .corrupt, .missingFile: true
    case .noCrop, .noText, .noCaption, .noTitle, .heldInEdit: false
    }
  }

  /// Chip order: sent back first, then missing pieces, then hard blocks.
  public var chipOrder: Int {
    switch self {
    case .heldInEdit: -1
    case .noCrop: 0
    case .noText: 1
    case .noCaption: 2
    case .noTitle: 3
    case .tooLong: 4
    case .captionTooLong: 5
    case .tooLarge: 6
    case .titleTooLong: 7
    case .corrupt: 8
    case .missingFile: 9
    }
  }

  /// Every kind in chip order.
  public static var inChipOrder: [ValidationIssue.Kind] {
    [.heldInEdit, .noCrop, .noText, .noCaption, .noTitle, .tooLong, .captionTooLong, .tooLarge, .titleTooLong, .corrupt,
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
