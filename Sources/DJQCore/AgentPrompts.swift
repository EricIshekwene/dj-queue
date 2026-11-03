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

  /// Markdown prompt asking an agent for song names: title suggestions and on-video text suggestions.
  public static func titles(for videoIds: [String], store: Store) throws -> String {
    let vids = try videoIds.compactMap { try store.video(id: $0) }
    guard !vids.isEmpty else { throw EngineError("No clips to ask about") }
    let sessions = Dictionary(uniqueKeysWithValues: try store.sessions().map { ($0.id, $0) })
    let settings = try store.settings()
    var md = """
    # Find the song names, titles and on-video text for these DJ clips

    ## Task
    For each clip below, find the correct song names (the tracks audible in the clip, usually a transition from one \
    song into the next). Then suggest two things, best first, each with a confidence from 0 to 1:
    - **Title** (`title_suggestions`): the song names on one line. It names the clip on every DJ Queue screen.
    - **Text on the video** (`text_suggestions`): what Eric will put on screen. Usually the same song names laid out \
    for a vertical video; you may add one short hook as an extra option.

    Eric picks both in DJ Queue — you only suggest.

    ## Context
    - Artist: DJ Lovd (DJ; amapiano / afrobeats sets). Clips are short vertical videos cut from a recorded live set.
    - Each clip comes from a set "part" (one continuous recording). `marked_start`/`marked_end` are Eric's markers \
    on that part's timeline (mm:ss); the clip file adds a few seconds of grace around them.
    - The raw marker tag is what Eric typed while marking — often lowercase, abbreviated or misspelled. Treat it as a \
    hint, not the answer.
    - Sources you may use, READ-ONLY: Eric's rekordbox library, history and crates (match the set date and the part \
    timeline), tracklists, the clip files / set recordings listed below, and your own knowledge.
    - Title style: one line, song names joined with " x " (never an arrow, no emoji), e.g. `Yayo x Johnny`.
    - Text-on-video style: the song names, short enough to read in a second. Long names go on lines with `x` alone \
    between them (`Song One\\nx\\nSong Two`); short pairs can stay on one line. A hook (e.g. `Piano is sweet!!`) is \
    a separate, lower-confidence suggestion and never replaces the song names.

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
        md += "- Title suggestions so far: none\n"
      } else {
        md += "- Title suggestions so far:\n"
        for x in sugg {
          let tracks = x.tracks.map { t in t.artist.map { "\(t.title) — \($0)" } ?? t.title }.joined(separator: "; ")
          md += "  - \"\(Captions.oneLine(x.text))\" (confidence \(x.confidence.map { String(format: "%.2f", $0) } ?? "?")"
            + "\(x.source.isEmpty ? "" : ", source \(x.source)")\(tracks.isEmpty ? "" : ", tracks: \(tracks)"))\n"
        }
      }
      if v.type == .short, let r = try store.resolvedVersion(videoId: v.id, number: 1, settings: settings) {
        let text = r.noText ? "no text" : r.hasText ? "\"\(lines(r.text))\"" : "none yet"
        md += "- Text on the video now: \(text)\(r.isDefault("text") ? "" : " (chosen by Eric)")\n"
      }
      let textSugg = try store.textSuggestions(videoId: v.id)
      if !textSugg.isEmpty {
        md += "- Text suggestions so far:\n"
        for x in textSugg {
          md += "  - \"\(lines(x.text))\" (confidence \(x.confidence.map { String(format: "%.2f", $0) } ?? "?")"
            + "\(x.source.isEmpty ? "" : ", source \(x.source)"))\n"
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
        ],
        "text_suggestions": [
          {"text": "Song One\\nx\\nSong Two", "confidence": 0.8, "source": "rekordbox history"},
          {"text": "Who knows this blend?", "confidence": 0.3, "source": "hook"}
        ]
      }
    ]
    """
    md += """
    ## Return exactly this JSON
    One array entry per clip (\(vids.count) clip\(vids.count == 1 ? "" : "s")), `video_id` copied from the headings above. \
    In `title_suggestions`, `text` is the one-line title and `tracks` lists the songs in order. In `text_suggestions`, \
    `text` is the text on the video (use `\\n` for line breaks). `confidence` 0–1; `source` says where you found it. \
    Either list may be left out for a clip.

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
    - Suggestions only: don't set titles, text, scores or anything else. Eric picks.
    - Don't guess silently: if you can't identify a track, give your best guess with a low confidence and say why in `source`.

    """
    return md
  }

  /// Line breaks shown as " / " so a multi-line text stays on one Markdown line.
  static func lines(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
      .joined(separator: " / ")
  }

  static func mmss(_ s: Double) -> String {
    let t = Int(max(0, s).rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
  }
}
