import Foundation

/// "Ask an agent" prompts (round 2): instead of guessing in the app, DJ Queue writes a ready-to-paste Markdown
/// prompt for Eric's own agent. Pure templating over stored data — deterministic, no inference.
public enum AgentPrompts {
  /// Suggestions below this confidence don't count as an answer.
  public static let confidentEnough = 0.6

  /// True when a clip has no title AND (no suggestions OR the best suggestion is below `confidentEnough`).
  public static func needsTitleHelp(_ video: Video, suggestions: [TitleSuggestion]) -> Bool {
    guard video.type == .short, video.titleText == nil else { return false }
    let best = suggestions.compactMap(\.confidence).max()
    return suggestions.isEmpty || (best ?? 0) < confidentEnough
  }

  public static func needsTitleHelp(_ video: Video, store: Store) throws -> Bool {
    needsTitleHelp(video, suggestions: try store.titleSuggestions(videoId: video.id))
  }

  /// Every short clip (not excluded/missing) that needs title help, in session order.
  public static func clipsNeedingTitleHelp(store: Store) throws -> [String] {
    try store.videos(where: "type='short-form' AND excluded=0 AND missing=0")
      .filter { try needsTitleHelp($0, store: store) }
      .sorted { ($0.sessionId, $0.part ?? 0, $0.start ?? 0, $0.name) < ($1.sessionId, $1.part ?? 0, $1.start ?? 0, $1.name) }
      .map(\.id)
  }

  /// The command an agent runs to hand its answer back (one file, many clips).
  public static func suggestCommand(file: String = "suggestions.json") -> String { "djq suggest --file \(file)" }

  /// Markdown prompt asking an agent for song names / overlay text for these clips.
  public static func titles(for videoIds: [String], store: Store) throws -> String {
    let vids = try videoIds.compactMap { try store.video(id: $0) }
    guard !vids.isEmpty else { throw EngineError("No clips to ask about") }
    let sessions = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0) })
    var md = """
    # Find the song names / overlay text for these DJ clips

    ## Task
    For each clip below, find the correct song names (the tracks audible in the clip, usually a transition from one \
    song into the next) and propose the overlay text Eric will put on the video. Give one or more suggestions per clip, \
    best first, each with a confidence from 0 to 1. Eric picks the title in DJ Queue — you only suggest.

    ## Context
    - Artist: DJ Lovd (DJ; amapiano / afrobeats sets). Clips are short vertical videos cut from a recorded live set.
    - Each clip comes from a set "part" (one continuous recording). `marked_start`/`marked_end` are Eric's markers \
    on that part's timeline (mm:ss); the clip file adds a few seconds of grace around them.
    - The raw marker tag is what Eric typed while marking — often lowercase, abbreviated or misspelled. Treat it as a \
    hint, not the answer.
    - Sources you may use, READ-ONLY: Eric's rekordbox library, history and crates (match the set date and the part \
    timeline), tracklists, the clip files / set recordings listed below, and your own knowledge.
    - Overlay text style: song names joined with " x " (never an arrow, no emoji), e.g. `Yayo x Johnny`; long names \
    may go on three lines `Song One` / `x` / `Song Two`.

    ## Clips


    """
    for v in vids {
      let s = sessions[v.sessionId]
      let sugg = try store.titleSuggestions(videoId: v.id)
      md += "### \(v.id)\n"
      md += "- Session: \(s.map { Captions.setName($0.name) } ?? "?")\(s?.date.map { " · \($0)" } ?? "")\n"
      md += "- Raw marker tag: `\(v.tag)`\n"
      md += "- Current title: \(v.titleText.map { "\"\($0)\"" } ?? "none")\n"
      if sugg.isEmpty {
        md += "- Suggestions so far: none\n"
      } else {
        md += "- Suggestions so far:\n"
        for x in sugg {
          let tracks = x.tracks.map { t in t.artist.map { "\(t.title) — \($0)" } ?? t.title }.joined(separator: "; ")
          md += "  - \"\(Captions.oneLine(x.text))\" (confidence \(x.confidence.map { String(format: "%.2f", $0) } ?? "?")"
            + "\(x.source.isEmpty ? "" : ", source \(x.source)")\(tracks.isEmpty ? "" : ", tracks: \(tracks)"))\n"
        }
      }
      md += "- Part: \(v.part.map(String.init) ?? "?")\n"
      md += "- Marked: \(v.markedStart.map(mmss) ?? "?") → \(v.markedEnd.map(mmss) ?? "?") on the part timeline"
        + (v.start.map { " (clip file starts at \(mmss($0)))" } ?? "") + "\n"
      md += "- Duration: \(mmss(v.duration))\n"
      md += "- Audio source: \(v.audio ?? "unknown")\n"
      md += "- Clip file: \((try? store.fileURL(for: v))??.path ?? v.file)\n\n"
    }
    let example = """
    [
      {
        "video_id": "\(vids[0].id)",
        "title_suggestions": [
          {
            "text": "Song One x Song Two",
            "tracks": [{"title": "Song One", "artist": "Artist A"}, {"title": "Song Two", "artist": "Artist B"}],
            "confidence": 0.8,
            "source": "rekordbox history"
          }
        ]
      }
    ]
    """
    md += """
    ## Return exactly this JSON
    One array entry per clip (\(vids.count) clip\(vids.count == 1 ? "" : "s")), `video_id` copied from the headings above; \
    `text` is the overlay text (use `\\n` for line breaks); `tracks` lists the songs in order; `confidence` 0–1; \
    `source` says where you found it.

    ```json
    \(example)
    ```

    ## Apply it
    Save the JSON to a file and run:

    ```
    \(suggestCommand())
    ```

    ## Rules
    - Never modify, move or delete session source files (Video/, Audio/, Other/, Clips/, CapCut projects) or the ids in videos.json.
    - Suggestions only: don't set titles, scores or anything else. Eric picks.
    - Don't guess silently: if you can't identify a track, give your best guess with a low confidence and say why in `source`.

    """
    return md
  }

  static func mmss(_ s: Double) -> String {
    let t = Int(max(0, s).rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
  }
}
