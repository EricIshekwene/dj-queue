import AppKit
import DJQCore
import SwiftUI

/// `DJQ_SNAPSHOT_EDITOR=1 DJQ_LIST_SORT_SCRIPT=<dir> DJQueueApp --snapshot <dir>` (round 32): every list's chosen sort
/// is what the screen shows, in the real main window on the scratch copy of real data. For each page and order it reads the ids the screen registered as
/// shown (`visibleIds`, the same order ⌘A, ⇧-click ranges and the editor's ↑/↓ use) and checks them against the
/// order. The Queue runs in all four layouts, with a day or not, and under a filter. The window sits off every display
/// and nothing goes through the system event queue. Exits 1 on a failed check and saves a capture of each step.
@MainActor
enum ListSortScript {
  static func run(model: AppModel, store: Store, out: URL) async -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      print("list-sort: \(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    model.refreshNow()
    SnapshotContext.resetUI(model)
    let dark = ProcessInfo.processInfo.environment["DJQ_EDITOR_LIVE_APPEARANCE"] == "dark"
    let window = WindowManager.makeMainWindow(model: model, make: SnapshotWindow.make)
    window.setContentSize(NSSize(width: Shot.standard.width, height: Shot.standard.height))
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    Backstage.show(window)
    defer { window.orderOut(nil); window.close() }

    func shot(_ file: String) async {
      try? await Task.sleep(for: .milliseconds(900))
      window.displayIfNeeded()
      guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
      view.cacheDisplay(in: view.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(file).png"))
    }
    /// What the screen shows, in order, once it has drawn.
    func shown(_ s: Screen) -> [Video] { (model.visibleIds[s] ?? []).compactMap(model.video) }
    func scores(_ vs: [Video]) -> String { vs.prefix(14).map { $0.score.map(String.init) ?? "–" }.joined(separator: " ") }
    /// Unscored photo posts first, then scores never going the wrong way.
    func inScoreOrder(_ vs: [Video], worstFirst: Bool) -> Bool {
      let free = vs.prefix { $0.needsNoScore && $0.score == nil }.count
      let rest = vs.dropFirst(free)
      guard !rest.contains(where: { $0.needsNoScore && $0.score == nil }) else { return false }
      let s = rest.map { $0.score ?? (worstFirst ? 101 : -1) }
      return zip(s, s.dropFirst()).allSatisfy { worstFirst ? $0 <= $1 : $0 >= $1 }
    }

    // MARK: Queue

    let prefs = ListPrefs.shared
    let all = model.queueClips
    let scheduled = all.filter { model.nextSlotByVideo[$0.id] != nil }
    print("list-sort: Queue \(all.count) clips, \(scheduled.count) with a day; posting order \(scores(all))")
    check("the sample has clips with a day and clips with scores out of order by day",
          scheduled.count >= 3 && !inScoreOrder(all, worstFirst: true) && !inScoreOrder(all, worstFirst: false))
    model.screen = .queue
    for direction in SortDirection.allCases {
      prefs.setSort(.queue, nil)
      model.update { $0.sort = direction }
      model.refreshNow()
      let worst = direction == .worstFirst
      for mode in DSViewMode.allCases {
        model.setViewMode(mode, for: .queue)
        await shot("queue-\(worst ? "worst" : "best")-\(mode.rawValue)")
        let vs = shown(.queue)
        print("list-sort: Queue \(direction.displayName) \(mode.rawValue): \(scores(vs))")
        check("Queue \(direction.displayName), \(mode.rawValue): every clip in score order",
              vs.count == all.count && inScoreOrder(vs, worstFirst: worst))
      }
    }
    // Under a filter and a status chip, the sort still wins.
    model.update { $0.sort = .worstFirst }
    model.refreshNow()
    model.setViewMode(.grid, for: .queue)
    prefs.setStatus(.queue, "scheduled")
    await shot("queue-worst-has-a-day")
    let withDay = shown(.queue)
    check("Queue › Has a day: only clips with a day, worst first",
          withDay.count == scheduled.count && withDay.allSatisfy { model.nextSlotByVideo[$0.id] != nil }
            && inScoreOrder(withDay, worstFirst: true))
    prefs.setStatus(.queue, nil)
    model.update { $0.sort = .bestFirst }
    model.refreshNow()
    if let kind = all.first(where: { !$0.isPhoto && !$0.isStill })?.kind {
      prefs.setFilter(.queue, ListFilterKey.kind, kind.rawValue)
      await shot("queue-best-kind-filter")
      let k = shown(.queue)
      check("Queue › Kind \(kind.displayName): only that kind, in score order",
            !k.isEmpty && k.allSatisfy { !$0.isPhoto && !$0.isStill && $0.kind == kind } && inScoreOrder(k, worstFirst: false))
      prefs.clearFilters(.queue)
    }
    // Next post first: the posting order, numbered.
    prefs.setSort(.queue, QueueOrder.postingOrder)
    model.setViewMode(.wide, for: .queue)
    await shot("queue-next-post-first")
    check("Queue › Next post first: posting order (days, then the clips waiting)",
          shown(.queue).map(\.id) == model.queueClips.map(\.id))
    prefs.setSort(.queue, nil)
    model.update { $0.sort = .worstFirst }
    model.refreshNow()
    model.setViewMode(.wide, for: .queue)
    await shot("queue-worst-cards")
    // "Move one place later" on a clip with no day: it shows one place later under the score order too.
    let before = shown(.queue).map(\.id)
    if let i = before.indices.dropLast().first(where: { model.nextSlotByVideo[before[$0]] == nil }) {
      let id = before[i]
      model.skipNext(id)
      model.refreshNow()
      await shot("queue-worst-moved-later")
      let after = shown(.queue).map(\.id)
      check("Queue › Move one place later (no day yet): one place later in the shown order",
            after.firstIndex(of: id) == i + 1 && after[i] == before[i + 1])
    } else {
      print("list-sort: no clip without a day to move later in this data")
    }

    // MARK: Edit, Library, Score

    for page in [ListPage.edit, .library, .score] {
      let screen: Screen = page == .edit ? .edit : page == .library ? .library : .score
      if page == .score && model.scoreList.isEmpty {
        // Nothing waits for a score in this copy: take the scores off a few clips from two sets (scratch copy only),
        // so Set order has sets to keep apart.
        let bySet = Dictionary(grouping: model.libraryAll.filter { $0.type == .short && !$0.needsNoScore && $0.score != nil },
                               by: \.sessionId)
        for (_, vs) in bySet.sorted(by: { $0.key < $1.key }).prefix(2) {
          for v in vs.prefix(3) { try? store.setScore(v.id, nil) }
        }
        model.refreshNow()
      }
      let source = page == .edit ? model.editList : page == .library ? model.libraryAll : model.scoreList
      guard !source.isEmpty else { print("list-sort: \(page.rawValue) is empty in this data, nothing to order"); continue }
      model.screen = screen
      model.setViewMode(.grid, for: screen)
      for sort in page.sorts {
        prefs.setSort(page, sort == page.defaultSort ? nil : sort.rawValue)
        await shot("\(page.rawValue)-\(sort.rawValue)")
        let vs = shown(screen).filter { $0.type == .short }
        let ok: Bool = switch sort {
        case .scoreHigh: inScoreOrder(vs.filter { !($0.needsNoScore && $0.score == nil) }, worstFirst: false)
        case .scoreLow: inScoreOrder(vs.filter { !($0.needsNoScore && $0.score == nil) }, worstFirst: true)
        case .natural where page == .edit: inScoreOrder(vs, worstFirst: true)
        case .newest: zip(vs, vs.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt }
        case .title: zip(vs, vs.dropFirst()).allSatisfy { model.displayName($0).localizedCaseInsensitiveCompare(model.displayName($1)) != .orderedDescending }
        case .session:
          zip(vs, vs.dropFirst()).allSatisfy {
            (model.sessionById[$0.sessionId]?.date ?? "") >= (model.sessionById[$1.sessionId]?.date ?? "")
          }
        case .natural:
          // Score's Set order: each set together, newest set first, then part and start within it.
          zip(vs, vs.dropFirst()).allSatisfy { a, b in
            let da = model.sessionById[a.sessionId]?.date ?? "", db = model.sessionById[b.sessionId]?.date ?? ""
            return a.sessionId == b.sessionId ? (a.part ?? 0, a.start ?? 0) <= (b.part ?? 0, b.start ?? 0) : da >= db
          } && Set(vs.map(\.sessionId)).count == vs.map(\.sessionId).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }.count
        }
        print("list-sort: \(page.rawValue) \(page.title(sort)): \(vs.count) shown · \(scores(vs))")
        check("\(page.rawValue.capitalized) › \(page.title(sort)): shown in that order", !vs.isEmpty && ok)
      }
      prefs.setSort(page, nil)
    }

    // MARK: Posts

    model.screen = .posts
    for tab in ["posted", "scheduled"] {
      for sort in ["newest", "oldest"] {
        prefs.setStatus(.posts, tab)
        prefs.setSort(.posts, sort)
        await shot("posts-\(tab)-\(sort)")
        let ps = (model.visibleIds[.posts] ?? []).compactMap { model.postById[$0] }
        let at: (PlatformPost) -> Date = { tab == "posted" ? ($0.postedAt ?? $0.scheduledAt) : $0.scheduledAt }
        let ok = zip(ps, ps.dropFirst()).allSatisfy { sort == "newest" ? at($0) >= at($1) : at($0) <= at($1) }
        print("list-sort: Posts \(tab) \(sort): \(ps.count) shown")
        check("Posts › \(tab.capitalized), \(sort == "newest" ? "Newest" : "Oldest") first: shown by date", !ps.isEmpty && ok)
      }
    }
    prefs.setSort(.posts, nil)
    prefs.setStatus(.posts, nil)

    print("list-sort: \(failures == 0 ? "all passed" : "\(failures) failed")")
    return failures == 0 ? 0 : 1
  }
}
