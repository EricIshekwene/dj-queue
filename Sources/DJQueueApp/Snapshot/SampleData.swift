import DJQCore
import Foundation

/// Plausible scores, edits, an approved week with posts in every state, a draft next week and 7 days of
/// heartbeats — written ONLY into the throwaway database copy used by `--snapshot`.
enum SampleData {
  /// Deterministic across runs (String.hashValue is seeded per process).
  static func stableHash(_ s: String) -> Int { s.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff } }

  static func seed(store: Store, clock: FixedClock, now: Date) throws {
    var st = try store.settings()
    st.postsPerDay = 1
    try store.save(st)
    let dm = DayMath(settings: st)
    let today = dm.key(now)
    let rules = PrefillRules.load(store.paths)

    let shorts = try store.videos(where: "type='short-form'").sorted { ($0.part ?? 0, $0.start ?? 0) < ($1.part ?? 0, $1.start ?? 0) }
    guard shorts.count >= 30 else { return }

    // Scores (48 scored, 14 to score), edits for 40 → ready, a few talking / excluded / missing.
    for (i, v) in shorts.enumerated() {
      clock.set(now.addingTimeInterval(-86400 * 3 + Double(i) * 60))
      if i < 48 {
        let h = stableHash(v.id) % 1000
        try store.setScore(v.id, 28 + (h * 7 + i * 13) % 68)
      }
      if i < 40 {
        var e = Edit()
        e.crop = CropRect(x: 1312, y: 0, w: 1215, h: 2160)
        try store.save(e, videoId: v.id)
        var ver = Version(number: 1)
        ver.text = Prefill.text(tag: v.tag, kind: .djVid, rules: rules)
        if ver.text?.isEmpty ?? true { ver.noText = true }
        ver.captionTemplateId = "set-link"
        try store.save(ver, videoId: v.id)
        if i % 9 == 4 {
          var v2 = Version(number: 2)
          v2.caption = "Who knows this blend? 👀"
          try store.save(v2, videoId: v.id)
        }
      }
      if [6, 19, 33].contains(i) { try store.setKind(v.id, .talking) }
    }
    try store.setExcluded(shorts[44].id, true)
    try store.setExcluded(shorts[45].id, true)
    try store.db.run("UPDATE videos SET missing=1, state='missing_file' WHERE id=?", [shorts[60].id])
    try store.db.run("UPDATE videos SET in_manifest=0 WHERE id=?", [shorts[61].id])
    try store.logEvent("relink", "Relinked \(shorts[3].name)", videoId: shorts[3].id)

    // This week: approved, one video per day, every platform.
    let thisWeek = dm.weekStart(of: now)
    let approvedAt = dm.at(dm.addDays(thisWeek, -1), minutes: 18 * 60 + 5)
    clock.set(approvedAt)
    try store.save(Week(weekStart: thisWeek, state: .approved, approvedAt: approvedAt))
    let ready = try store.videos(where: "type='short-form' AND state='ready'")
      .sorted { ($0.score ?? 0, $0.part ?? 0, $0.start ?? 0) < ($1.score ?? 0, $1.part ?? 0, $1.start ?? 0) }
    var pool = ready
    let days = dm.weekDays(thisWeek)
    var weekSlots: [(String, PlanSlot)] = []
    for day in days where !pool.isEmpty {
      let v = pool.removeFirst()
      let s = PlanSlot(id: newId(), date: day, position: 0, videoId: v.id, pinned: day == days[2], weekStart: thisWeek)
      try store.save(s)
      weekSlots.append((day, s))
    }

    func post(_ s: PlanSlot, _ p: Platform, _ final: PostState, version: Int = 1, error: (ErrorType, String, String?)? = nil,
              url: Bool = true, metrics: PostMetrics? = nil) throws {
      let at = dm.at(s.date, minutes: st.slot(for: p))
      clock.set(approvedAt)
      var post = PlatformPost(id: newId(), videoId: s.videoId, platform: p, versionNo: version, attemptNo: 1, kind: .regular,
                              planSlotId: s.id, scheduledAt: at, renderId: nil, state: .planned, publisher: "manual", externalId: nil,
                              url: nil, postedAt: nil, errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil,
                              metrics: nil, createdAt: approvedAt, updatedAt: approvedAt)
      try store.save(post)
      let steps: [(PostState, TimeInterval)] = [(.rendering, -86400 * 2), (.rendered, -86400 * 2 + 140), (.due, 0)]
      for (state, off) in steps {
        if state == final { break }
        if at.addingTimeInterval(off) > now { break }
        clock.set(at.addingTimeInterval(off))
        post.state = state
        try store.save(post)
      }
      if final == .rendering || final == .rendered || final == .planned || final == .due {
        if post.state != final {
          clock.set(min(now, at.addingTimeInterval(-3600)))
          post.state = final
          try store.save(post)
        }
        return
      }
      clock.set(final == .overdue ? dm.at(dm.addDays(s.date, 1), minutes: 8 * 60) : at.addingTimeInterval(Double(10 + stableHash(p.rawValue) % 40) * 60))
      post.state = final
      if final == .posted {
        let host = p.urlHosts[0]
        post.url = url ? "https://www.\(host)/@djlovd/\(String(post.id.prefix(8)))" : nil
        post.postedAt = clock.now
        post.metrics = metrics
      }
      if let error {
        post.errorType = error.0
        post.errorMessage = error.1
        post.rawResponse = error.2
      }
      try store.save(post, note: error?.1)
    }

    for (day, s) in weekSlots {
      for p in st.activePlatforms {
        let past = day < today
        if past {
          if day == days[3] && p == .instagram {
            try post(s, p, .copyrightBlocked, error: (.copyrightBlocked, "Audio unavailable: this song is restricted in your region",
                                                      "{\"error\":{\"code\":\"MUSIC_COPYRIGHT\",\"message\":\"Audio unavailable\",\"fbtrace_id\":\"AbX9…\"}}"))
          } else if day == days[4] && p == .x {
            try post(s, p, .failed, error: (.tooLong, "Video longer than 2:20", nil))
          } else if day == days[5] && p == .tiktok {
            try post(s, p, .overdue)
          } else if day == days[1] && p == .threads {
            try post(s, p, .skipped)
          } else {
            try post(s, p, .posted, metrics: p == .tiktok ? PostMetrics(views: 1200 + stableHash(s.videoId) % 4000, likes: 140, at: now) : nil)
          }
        } else if day == today {
          switch p {
          case .facebook, .threads: try post(s, p, .posted)
          case .youtube: try post(s, p, .due)
          case .tiktok: try post(s, p, .rendering)
          default: try post(s, p, .rendered)
          }
        } else {
          try post(s, p, .planned)
        }
      }
      try store.refreshState(videoId: s.videoId)
    }

    // Next week: draft proposal from the rest of the backlog + a retry and a repost (W.S5).
    let nextWeek = dm.addDays(thisWeek, 7)
    clock.set(now.addingTimeInterval(-600))
    try store.save(Week(weekStart: nextWeek, state: .draft, approvedAt: nil))
    for day in dm.weekDays(nextWeek) where !pool.isEmpty {
      let v = pool.removeFirst()
      try store.save(PlanSlot(id: newId(), date: day, position: 0, videoId: v.id, pinned: false, weekStart: nextWeek))
    }
    if let (_, s) = weekSlots.first {
      let tomorrow = dm.addDays(today, 1)
      let retryAt = dm.at(tomorrow, minutes: st.slot(for: .x) + 180)
      try store.save(PlatformPost(id: newId(), videoId: weekSlots[4].1.videoId, platform: .x, versionNo: 1, attemptNo: 2, kind: .retry,
                                  planSlotId: nil, scheduledAt: retryAt, renderId: nil, state: .planned, publisher: "manual",
                                  externalId: nil, url: nil, postedAt: nil, errorType: nil, errorMessage: nil, rawResponse: nil,
                                  resolution: nil, metrics: nil, createdAt: now, updatedAt: now))
      try store.save(PlatformPost(id: newId(), videoId: s.videoId, platform: .instagram, versionNo: 2, attemptNo: 2, kind: .repost,
                                  planSlotId: nil, scheduledAt: dm.at(dm.addDays(today, 3), minutes: st.slot(for: .instagram) + 180),
                                  renderId: nil, state: .planned, publisher: "manual", externalId: nil, url: nil, postedAt: nil,
                                  errorType: nil, errorMessage: nil, rawResponse: nil, resolution: nil, metrics: nil, createdAt: now, updatedAt: now))
    }
    try store.save(Render(id: newId(), videoId: weekSlots.last?.1.videoId ?? shorts[0].id, versionNo: 1, editHash: "pending", scope: "all",
                          outputPath: nil, coverPath: nil, loudness: nil, duration: nil, size: nil, status: .pending, error: nil,
                          createdAt: now, deletedAt: nil))

    // 7 days of heartbeats: awake 8:30–23:45, Mac off Sat 17:30–21:00 (missed TikTok), asleep overnight.
    clock.set(now)
    try store.db.run("DELETE FROM heartbeats WHERE at>?", [now])  // real runs of the dev DB after the frozen clock
    try store.db.transaction {
      for d in -6...0 {
        let day = dm.addDays(today, d)
        var t = dm.at(day, minutes: 8 * 60 + 30 + (d == -3 ? 95 : 0))
        let end = min(now.addingTimeInterval(-40), dm.at(day, minutes: 23 * 60 + 45))
        try store.heartbeat(.start, at: t)
        while t < end {
          let m = dm.calendar.dateComponents([.hour, .minute], from: t)
          let mins = (m.hour ?? 0) * 60 + (m.minute ?? 0)
          if day == days[5], mins >= 17 * 60 + 30, mins < 21 * 60 {
            t = t.addingTimeInterval(60)
            continue
          }
          try store.heartbeat(.tick, at: t)
          t = t.addingTimeInterval(60)
        }
        if d < 0 { try store.heartbeat(.sleep, at: end) }
      }
      try store.heartbeat(.tick, at: now.addingTimeInterval(-40))
    }
    for v in try store.videos() { try store.refreshState(videoId: v.id) }
  }
}
