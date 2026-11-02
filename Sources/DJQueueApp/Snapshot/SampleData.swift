import DJQCore
import Foundation

/// Plausible scores, edits, an approved week with posts in every state, a draft next week and 7 days of
/// heartbeats — written ONLY into the throwaway database copy used by `--snapshot`.
enum SampleData {
  /// Made-up sample titles for the throwaway snapshot DB (never shown for real data).
  static let sampleTitles = [
    "Midnight Run x Afterglow", "Golden Hour Blend", "Low Tide x Paper Moon", "Velvet Room Transition", "Sunday Drift",
    "Neon Harbour x Slow Bloom", "Late Train Edit", "Copper Sky x Warm Static", "Open Window Groove", "Blue Hour Switch",
  ]

  /// "A x B" → two tracks with a made-up artist each.
  static func sampleTracks(_ title: String) -> [Track] {
    title.components(separatedBy: " x ").enumerated().map { i, t in Track(title: t, artist: ["Sample Artist", "Demo Collective"][i % 2]) }
  }

  /// Deterministic across runs (String.hashValue is seeded per process).
  static func stableHash(_ s: String) -> Int { s.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff } }

  static func seed(store: Store, clock: FixedClock, now: Date) throws {
    var st = try store.settings()
    st.postsPerDay = 1
    try store.save(st)
    let dm = DayMath(settings: st)
    let today = dm.key(now)

    // Throwaway copy only: start from an empty plan so seeding never collides with an existing one.
    for t in ["plan_slots", "weeks", "platform_posts", "post_history", "renders", "sent_notifications"] {
      try store.db.run("DELETE FROM \(t)")
    }

    let shorts = try store.videos(where: "type='short-form'").sorted { ($0.part ?? 0, $0.start ?? 0) < ($1.part ?? 0, $1.start ?? 0) }
    guard shorts.count >= 30 else { return }

    // Scores (48 scored, 14 to score); clips 0–39 edited → ready (two thirds titled, the rest "No text");
    // 40–47 need edit with a mix of missing pieces; title suggestions on a spread of clips (some low-confidence so
    // "Ask an agent" shows, some none); a few talking / excluded / missing. Fixed sample strings only.
    for (i, v) in shorts.enumerated() {
      clock.set(now.addingTimeInterval(-86400 * 3 + Double(i) * 60))
      if i < 48 {
        let h = stableHash(v.id) % 1000
        try store.setScore(v.id, 28 + (h * 7 + i * 13) % 68)
      }
      let titled = i % 3 != 2 && ![42, 43, 46, 47].contains(i)
      if titled && i < 48 { try store.setTitle(v.id, sampleTitles[i % sampleTitles.count], source: "app") }
      if !titled || i >= 48 {
        let n = (i / 3) % 4  // 0 = none, 1–3 suggestions
        if n > 0 {
          let list = (0..<n).map { k -> SuggestionInput in
            let t = sampleTitles[(i + k * 5 + 3) % sampleTitles.count]
            return SuggestionInput(text: t, tracks: sampleTracks(t), confidence: i % 2 == 0 ? 0.82 - Double(k) * 0.1 : 0.35,
                                   source: "sample")
          }
          try store.addSuggestions(videoId: v.id, list, origin: "agent")
        }
      }
      if i >= 40 && i < 48 {
        // Needs edit: 40–41 no crop (titled) · 42–43 crop but no text (suggestions) · 46 nothing yet · 47 crop +
        // title but the whole file as trim (too long for some platforms when the clip is long).
        if [42, 43, 47].contains(i) {
          var e = Edit()
          e.crop = CropRect(x: 1312, y: 0, w: 1215, h: 2160)
          if i == 47 { e.trimIn = 0; e.trimOut = v.duration }
          try store.save(e, videoId: v.id)
        }
        if i == 47 { try store.setTitle(v.id, sampleTitles[1], source: "app") }
      }
      if i < 40 {
        var e = Edit()
        e.crop = CropRect(x: 1312, y: 0, w: 1215, h: 2160)
        try store.save(e, videoId: v.id)
        var ver = Version(number: 1)
        if !titled { ver.noText = true }
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

    // Sample renders point at the source clip so Today can offer a draggable file (throwaway DB only).
    var renderFor: [String: String] = [:]
    func sampleRender(_ videoId: String) throws -> String {
      if let r = renderFor[videoId] { return r }
      guard let v = try store.video(id: videoId), let url = try store.fileURL(for: v) else { return "" }
      let r = Render(id: newId(), videoId: videoId, versionNo: 1, editHash: "sample", scope: "all", outputPath: url.path,
                     coverPath: nil, loudness: nil, duration: v.duration, size: v.fileSize, status: .done, error: nil,
                     createdAt: now, deletedAt: nil)
      try store.save(r)
      renderFor[videoId] = r.id
      return r.id
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
      if ![.planned, .rendering].contains(final) { post.renderId = try sampleRender(s.videoId) }
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
