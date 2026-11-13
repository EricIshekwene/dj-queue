import AppKit
import DJQCore
import SwiftUI

/// Editor-only snapshots and a live run, from a throwaway copy of the dev database (never the source DB).
///
/// - `DJQ_SNAPSHOT_EDITOR=1 DJQueueApp --snapshot <dir>` renders `editor-NN-<name>-{light,dark}.png` at 1440×900
///   (stills stand in for the player). Needs the one-line hook in `SnapshotRunner.run`.
///   `DJQ_EDITOR_VIDEO=<id prefix>` picks the clip (default: the first short clip with suggestions, else with markers);
///   `DJQ_SNAPSHOT_ONLY=<substring>` filters shots.
/// - `DJQ_EDITOR_LIVE=<seconds>` instead opens the real editor (live player) in a backstage window for that long and prints
///   `editor-live: window <number>`. `DJQ_EDITOR_LIVE_PNG=<file>` captures it.
/// - `DJQ_BULK_CAPTION_SCRIPT=<dir>` drives the main window's Caption dialog (`BulkCaptionScript`).
/// - `DJQ_BULK_CROP_SCRIPT=<dir>` drives the Crop dialog (`BulkCropScript`).
/// - `DJQ_EDITOR_GROUP_SCRIPT=<dir>` makes a hashtag group in the real editor (`EditorGroupScript`);
///   `DJQ_EDITOR_CAPTION_SCRIPT=<dir>` drives the real caption field (`EditorCaptionScript`);
///   `DJQ_SETTINGS_GROUP_SCRIPT=<dir>` drives the real Settings group rows (`SettingsGroupScript`);
///   `DJQ_EDITOR_KEYS_SCRIPT=<dir>` drives the editor's keys and the arrow step (`EditorKeysScript`, round 19);
///   `DJQ_TRIM_MARKERS_SCRIPT=<dir>` drives the trim handles, zoom and M markers (`TrimMarkersScript`, round 24);
///   `DJQ_VERSION_TRIM_SCRIPT=<dir>` drives a version's own trim, the Trim switch and undo (`VersionTrimScript`, round 30);
///   `DJQ_EDITOR_TEMPLATE_SCRIPT=<dir>` drives the template actions and part chips (`EditorTemplateScript`);
///   `DJQ_EDITOR_DEFAULTS_SCRIPT=<dir>` drives "Make default for new clips…" (`EditorDefaultsScript`, round 29);
///   `DJQ_TEXT_LAYERS_SCRIPT=<dir>` drives timed texts end to end, export included (`TextLayersScript`);
///   `DJQ_REPOST_READY_SCRIPT=<dir>` drives Ready to repost and bulk edits on versions (`RepostReadyScript`);
///   `DJQ_TEXT_FIELDS_SCRIPT=<dir>` clicks and types in every kind of multi-line box (`TextFieldsScript`, round 25);
///   `DJQ_DESELECT_SCRIPT=<dir>` clicks empty spots to let go of a text, a trim handle and a field (`DeselectScript`, round 28).
@MainActor
enum EditorSnapshot {
  static func run(outputDir: String) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    do {
      let out = URL(fileURLWithPath: outputDir)
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      let src = Paths.standard
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("djq-editor-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: tmp) }
      var paths = Paths(root: src.root, appSupport: tmp.appendingPathComponent("support"), logs: tmp.appendingPathComponent("logs"),
                        launchAgents: tmp.appendingPathComponent("LaunchAgents"))
      paths.photosOverride = tmp.appendingPathComponent("Photos")  // round 21: this run's photo posts stay in its own folder
      try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: src.database.path) {
        try Store(paths: src).db.backup(to: paths.database.path)
      }
      let store = try Store(paths: paths)
      if try store.videos().isEmpty { try Intake(store: store).run() }
      // View preferences go to a throwaway defaults suite, never the app's.
      let suite = "djq-editor-snapshot-\(UUID().uuidString)"
      EditorModel.defaults = UserDefaults(suiteName: suite) ?? .standard
      defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

      let shorts = try store.videos(where: "type='short-form' AND excluded=0 AND missing=0").sorted { $0.name < $1.name }
      guard !shorts.isEmpty else { throw EngineError("no short clips in the dev database") }
      let pick: Video = try {
        if let p = env["DJQ_EDITOR_VIDEO"], let v = shorts.first(where: { $0.id.hasPrefix(p) }) { return v }
        if let v = try shorts.first(where: { !(try store.titleSuggestions(videoId: $0.id)).isEmpty }) { return v }
        return shorts.first { $0.markerIn != nil } ?? shorts[0]
      }()
      let ids = shorts.map(\.id)

      if env["DJQ_EDITOR_SELFTEST"] != nil { return selfTest(store: store, ids: ids, start: pick.id) }
      if let secs = env["DJQ_EDITOR_LIVE"].flatMap(Double.init) { return await live(store: store, video: pick.id, ids: ids, seconds: secs) }
      if let dir = env["DJQ_TEXT_LAYERS_SCRIPT"] {
        return await TextLayersScript.run(store: store, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_BULK_CROP_SCRIPT"] {
        return await BulkCropScript.run(store: store, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_BULK_CAPTION_SCRIPT"] {
        return await BulkCaptionScript.run(store: store, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_EDITOR_GROUP_SCRIPT"] {
        return await EditorGroupScript.run(store: store, video: pick.id, ids: ids, dir: dir,
                                           appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_EDITOR_TEMPLATE_SCRIPT"] {
        return await EditorTemplateScript.run(store: store, video: pick.id, ids: ids, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_EDITOR_DEFAULTS_SCRIPT"] {
        return await EditorDefaultsScript.run(store: store, video: pick.id, ids: ids, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_SETTINGS_GROUP_SCRIPT"] {
        return await SettingsGroupScript.run(store: store, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_EDITOR_KEYS_SCRIPT"] {
        return await EditorKeysScript.run(store: store, video: pick.id, ids: ids, dir: dir,
                                          appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_VERSION_TRIM_SCRIPT"] {
        return await VersionTrimScript.run(store: store, ids: ids, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_TRIM_MARKERS_SCRIPT"] {
        return await TrimMarkersScript.run(store: store, video: pick.id, ids: ids, dir: dir,
                                           appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_PHOTO_EDITOR_SCRIPT"] {
        try SampleData.addPhotoPosts(store: store, now: store.clock.now, scratch: tmp.appendingPathComponent("photo-samples"))
        return await PhotoEditorScript.run(store: store, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_REPOST_READY_SCRIPT"] {
        return await RepostReadyScript.run(store: store, dir: dir, appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_DESELECT_SCRIPT"] {
        return await DeselectScript.run(store: store, video: pick.id, ids: ids, dir: dir,
                                        appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_TEXT_FIELDS_SCRIPT"] {
        return await TextFieldsScript.run(store: store, video: pick.id, ids: ids, dir: dir,
                                          appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }
      if let dir = env["DJQ_EDITOR_CAPTION_SCRIPT"] {
        return await EditorCaptionScript.run(store: store, video: pick.id, ids: ids, dir: dir,
                                             appearance: env["DJQ_EDITOR_LIVE_APPEARANCE"] ?? "light")
      }

      let model = EditorModel(store: store, videoId: pick.id, snapshotMode: true)
      // A clip with no title and no suggestions for the "Ask an agent" state.
      let helpless = shorts.first { $0.id != pick.id && $0.titleText == nil && ((try? store.titleSuggestions(videoId: $0.id)) ?? []).isEmpty }
      print("editor-snapshot: clip \(pick.id.prefix(8)) “\(pick.displayName)”, \(model.suggestions.count) suggestions, \(model.textSuggestions.count) text suggestions")

      var shots: [(String, () -> Void)] = []
      func shot(_ name: String, _ setup: @escaping () -> Void) { shots.append((name, setup)) }
      let reset = {
        EditorDisclosures.shared.closeAll()
        model.compare = false
        model.openPlatformCaption = nil
        model.toast = nil
      }
      shot("01-title-suggestions") { reset(); model.canvasMode = .zones; model.zonePlatforms = [.tiktok, .instagram]; model.scrollTarget = .title }
      shot("02-frame") { reset(); model.canvasMode = .frame; model.scrollTarget = .frame }
      shot("03-text") { reset(); model.canvasMode = .zones; model.scrollTarget = .text }
      shot("04-caption") { reset(); model.canvasMode = .zones; model.scrollTarget = .caption }
      shot("05-cover") { reset(); model.canvasMode = .zones; model.scrollTarget = .cover }
      shot("06-platforms") { reset(); model.canvasMode = .zones; model.scrollTarget = .platforms }
      shot("07-zones-3-platforms") {
        reset(); model.canvasMode = .zones; model.zonePlatforms = [.tiktok, .instagram, .youtube]; model.scrollTarget = .frame
      }
      shot("08-zones-cards") { reset(); model.canvasMode = .zones; model.zonePlatforms = [.facebook, .threads, .x]; model.scrollTarget = .title }
      for (i, p) in EditorPlatforms.order.enumerated() {
        shot(String(format: "%02d-preview-%@", 10 + i, p.rawValue)) {
          reset(); model.canvasMode = .preview; model.previewPlatform = p; model.scrollTarget = .caption
        }
      }
      shot("16-preview-compare") { reset(); model.canvasMode = .preview; model.previewPlatform = .tiktok; model.compare = true }
      shot("17-caption-over-limit") {
        reset()
        model.canvasMode = .preview
        model.previewPlatform = .x
        // A long typed caption (throwaway DB) so X (280) and Threads (500) go over.
        let long = (model.title ?? model.rawTag) + " — live at the Afroween Jazz Piano set. "
          + "That log drum switch into the second track still gets me every time. "
          + "Full set on YouTube, link in bio. Which blend should I post next? Tell me in the comments.\n{hashtags}"
        model.updateVersion { $0.caption = long }
        model.scrollTarget = .caption
      }
      shot("18-caption-x-own") {
        reset()
        model.canvasMode = .preview
        model.previewPlatform = .x
        model.dropHashtags(.x)
        model.toast = nil
        model.writePlatformCaption(.x)
      }
      // Changes v1's text, so it runs after every shot that shows the default text.
      if let s = model.textSuggestions.first {
        shot("18b-text-suggestion-chosen") {
          reset(); model.resetVersion(["caption", "platformCaptions"]); model.canvasMode = .zones; model.acceptText(s)
          model.scrollTarget = .text
        }
      }
      if let h = helpless {
        shot("19-title-ask-agent") {
          reset(); model.resetVersion(["caption", "platformCaptions"]); model.load(h.id)
          model.canvasMode = .zones; model.scrollTarget = .title
        }
      }
      // Round 6 (F1, F2, F6). They change the throwaway DB, so they run last.
      shot("r6-cover-meaning") { reset(); model.canvasMode = .zones; model.scrollTarget = .cover }
      shot("r6-youtube-title-over") {
        reset()
        model.canvasMode = .preview
        model.previewPlatform = .youtube
        model.updateVersion { $0.youtubeTitle = String(repeating: "Afroween Jazz Piano blend, the log drum switch ", count: 3) }
        model.scrollTarget = .caption
      }
      shot("r6-youtube-title-template-shortened") {
        reset()
        model.updateVersion { $0.youtubeTitle = "" }
        model.updateVersion { $0.text = "Midnight Run into Afterglow into Low Tide into Paper Moon, the whole Afroween Jazz Piano closing run, part two" }
        model.canvasMode = .preview
        model.previewPlatform = .youtube
        model.scrollTarget = .caption
      }
      // F6: a clip longer than Facebook's limit, played whole.
      if let long = shorts.filter({ $0.id != pick.id && $0.duration > 100 && $0.duration < 135 }).first
          ?? shorts.filter({ $0.duration > 100 }).min(by: { $0.duration < $1.duration }) {
        let whole = {
          model.load(long.id)
          model.updateEdit { $0.trimIn = 0; $0.trimOut = long.duration; $0.platformTrims = [:]; $0.skippedPlatforms = [] }
        }
        shot("r6-long-clip") { reset(); whole(); model.canvasMode = .zones; model.scrollTarget = .platforms }
        shot("r6-long-clip-trimmed-facebook") {
          reset(); whole(); model.addPlatformTrim(.facebook); model.canvasMode = .zones; model.scrollTarget = .platforms
        }
        shot("r6-long-clip-skipped-facebook") {
          reset(); whole(); model.setPosting(.facebook, false); model.canvasMode = .zones; model.scrollTarget = .platforms
        }
      }
      // Round 7: the caption section as Eric uses it — his own groups, the real caption in the field, typing, groups and
      // extra tags updating it in place, template switch + ⌘Z, a 2,000+ character caption, YouTube title templates,
      // a held clip and a missing-template clip. They change the throwaway DB, so they run last.
      let groups = [HashtagSet(id: "r7-piano", name: "Piano", category: "My groups", tags: ["#amapiano", "#piano"], sort: 0),
                    HashtagSet(id: "r7-sa", name: "Piano · SA", category: "My groups", tags: ["#amapianosa", "#yanos"], sort: 1)]
      let seed = {
        for g in groups { try? store.save(g) }
        if var st = try? store.settings(), !st.youtubeTitleTemplates.contains(where: { $0.id == "r7-live" }) {
          st.youtubeTitleTemplates.append(TitleTemplate(id: "r7-live", name: "Live set", template: "{text} (live set) | DJ Lovd"))
          try? store.save(st)
        }
        model.load(pick.id)
        model.resetVersion(["caption", "platformCaptions", "hashtagSetIds", "extraHashtags", "captionTemplateId",
                            "youtubeTitle", "youtubeTitleTemplateId"])
      }
      let typed = "Eric's own words about this blend 🎹\n\nFull set on YouTube — link in bio"
      shot("r7-01-caption-template") { reset(); seed(); model.canvasMode = .preview; model.previewPlatform = .instagram; model.scrollTarget = .caption }
      shot("r7-02-group-on") { reset(); model.setHashtagSets(["r7-piano"]); model.scrollTarget = .caption }
      shot("r7-03-typed-custom") {
        reset(); model.typeCaption(typed + "\n#amapiano #piano"); model.commitCaptionDraft(); model.scrollTarget = .caption
      }
      shot("r7-04-second-group-in-place") { reset(); model.setHashtagSets(["r7-piano", "r7-sa"]); model.scrollTarget = .caption }
      shot("r7-05-extra-tags-no-duplicate") { reset(); model.setExtraHashtags(["#djlovd", "#piano"]); model.scrollTarget = .caption }
      shot("r7-06-template-switch") { reset(); model.setCaptionTemplate("question"); model.toast = nil; model.scrollTarget = .caption }
      shot("r7-07-undo-brings-text-back") { reset(); model.undo(); model.toast = nil; model.scrollTarget = .caption }
      shot("r7-08-long-caption-2000") {
        reset()
        var long = ""
        while long.count < 2050 { long += "That log drum switch into the second track still gets me every time, live at the Afroween Jazz Piano set. " }
        model.typeCaption(long + "\n#amapiano #piano #amapianosa #yanos #djlovd"); model.commitCaptionDraft()
        model.canvasMode = .zones; model.scrollTarget = .caption
      }
      shot("r7-09-youtube-template-switch") {
        reset(); model.resetCaptionToTemplate(); model.setYouTubeTitleTemplate("r7-live"); model.toast = nil
        model.canvasMode = .preview; model.previewPlatform = .youtube; model.scrollTarget = .caption
      }
      shot("r7-10-youtube-title-typed") {
        reset(); model.typeYouTubeTitle("Afroween Jazz Piano — the log drum switch | DJ Lovd")
        model.canvasMode = .preview; model.previewPlatform = .youtube; model.scrollTarget = .caption
      }
      if let held = shorts.first(where: { $0.id != pick.id && $0.titleText != nil }) ?? shorts.first(where: { $0.id != pick.id }) {
        shot("r7-11-held-clip") {
          reset(); try? store.setHeldInEdit(held.id, true); model.load(held.id); model.canvasMode = .zones; model.scrollTarget = .title
        }
        shot("r7-12-missing-template") {
          reset()
          model.load(held.id)
          try? store.setHeldInEdit(held.id, false)
          model.load(held.id)
          model.updateVersion { $0.captionTemplateId = "deleted-template"; $0.caption = nil }
          model.flushAndWait()
          model.load(held.id)
          model.canvasMode = .zones; model.scrollTarget = .caption
        }
      }
      // v0.8.1: hashtag groups made in the editor, from no groups at all. Empty → form → filled → saved (group on,
      // caption updated), a duplicate name, editing a group, a read-only clip.
      let clearGroups = {
        for g in (try? store.hashtagSets()) ?? [] { try? store.deleteHashtagSet(g.id) }
        if var st = try? store.settings() { st.defaults.hashtagSetIds = []; try? store.save(st) }
        model.load(pick.id)
        model.resetVersion(["caption", "platformCaptions", "hashtagSetIds", "extraHashtags", "captionTemplateId"])
      }
      let inCaption = { model.canvasMode = .preview; model.previewPlatform = .instagram; model.scrollTarget = .caption }
      // v0.8.3: a blank group left by an older build. Alone it's no chip, just the empty state; with tags it's usable.
      shot("blank-01-only-a-blank-group") {
        reset(); clearGroups()
        try? store.save(HashtagSet(id: "b-blank", name: "", category: "Dj", tags: [], sort: 0))
        model.load(pick.id); inCaption()
      }
      shot("blank-02-blank-name-with-tags") {
        reset()
        try? store.save(HashtagSet(id: "b-untitled", name: "  ", category: "My groups", tags: ["#amapiano", "#piano"], sort: 1))
        try? store.save(HashtagSet(id: "b-named", name: "Piano · SA", category: "My groups", tags: ["#amapianosa"], sort: 2))
        model.load(pick.id); model.setHashtagSets(["b-untitled"]); inCaption()
      }
      shot("tpl-01-set-as-default") {
        reset(); clearGroups(); model.setCaptionTemplate("short"); inCaption()
      }
      shot("g-01-empty") { reset(); clearGroups(); inCaption() }
      shot("g-02-form-open") { reset(); model.openGroupForm(); inCaption() }
      shot("g-03-form-filled") {
        reset(); model.groupForm = EditorGroupForm(name: "Piano", tags: "Amapiano, #PIANO yanos"); inCaption()
      }
      shot("g-04-saved-group-on") {
        reset(); _ = model.saveGroup(name: "Piano", tags: "Amapiano, #PIANO yanos"); inCaption()
      }
      shot("g-05-beside-chips") { reset(); model.toast = nil; inCaption() }
      shot("g-06-duplicate-name") {
        reset(); model.groupForm = EditorGroupForm(name: "piano", tags: "#other"); inCaption()
      }
      shot("g-07-edit-group") {
        // This clip uses the group and now has a scheduled post, so the form says what saving keeps.
        reset()
        _ = try? store.db.run("""
          INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
          VALUES('g-post',?,'x',1,1,'regular',0,'planned','manual',0,0)
          """, [pick.id])
        model.openGroupForm(model.sets.first); inCaption()
      }
      if let broken = shorts.first(where: { $0.id != pick.id }) {
        shot("g-08-read-only-clip") {
          reset()
          model.groupForm = nil
          _ = try? store.db.run("INSERT OR REPLACE INTO edits(video_id,json,updated_at) VALUES(?,'not json',0)", [broken.id])
          model.load(broken.id)
          print("editor-snapshot: read-only \(model.readOnly), reason \(model.groupsOffReason ?? "none")")
          model.canvasMode = .zones; model.scrollTarget = .caption
        }
      }
      // Round 16: the closed rows, then timed texts with Advanced open. Last, because they change the clip.
      let timed = shorts.first { $0.id != pick.id && $0.id != shorts.first(where: { $0.id != pick.id })?.id } ?? pick
      shot("r16-closed-rows") { reset(); model.groupForm = nil; model.load(timed.id); model.canvasMode = .zones }
      shot("r16-three-texts") {
        reset()
        let d = model.trim.duration
        let like = model.resolved.firstLayer
        var second = TextLayers.new(text: "Second hook", like: like, start: 1, end: min(d, 6))
        second.posY = 0.3
        second.look = TextLook(color: "#FF3B30", font: .impact)
        var third = TextLayers.new(text: "Third line", like: like, start: 4, end: min(d, 9))
        third.posY = 0.72
        third.style = .outline
        model.updateVersion { $0.moreText = [second, third] }
        model.selectText(second.id)
        EditorDisclosures.shared.set(.advanced, true)
        model.playback.seek(model.trim.start + 5)
        model.scrollTarget = .text
      }
      if let only = env["DJQ_SNAPSHOT_ONLY"] { shots = shots.filter { $0.0.contains(only) } }

      for (name, setup) in shots {
        setup()
        model.flushAndWait()
        try await DSGallerySnapshot.render(AnyView(EditorView(model: model, videoIds: ids, onDone: {})),
                                           size: CGSize(width: 1440, height: 900), name: "editor-\(name)", to: out)
        print("editor-snapshot: \(name)")
      }
      print("editor-snapshot: wrote \(shots.count * 2) PNGs to \(out.path)")
      return 0
    } catch {
      FileHandle.standardError.write(Data("editor snapshot failed: \(error)\n".utf8))
      return 1
    }
  }

  /// `DJQ_EDITOR_SELFTEST=1`: exercises the model paths the header/keyboard use (⌘] = `load(next)`, Done/⌘↩ =
  /// `flushAndWait()`) and the "no-op click stores nothing" rules against the throwaway DB. Prints PASS/FAIL.
  private static func selfTest(store: Store, ids: [String], start: String) -> Int32 {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
      print("editor-selftest: \(ok ? "PASS" : "FAIL") \(name)")
      if !ok { failures += 1 }
    }
    guard let i = ids.firstIndex(of: start), ids.count > 2 else { print("editor-selftest: need 3 clips"); return 1 }
    let next = ids[(i + 1) % ids.count], third = ids[(i + 2) % ids.count]
    let m = EditorModel(store: store, videoId: start, snapshotMode: true)
    // Typed title, then ⌘] (no blur): the header calls load(next).
    m.titleDraft = "Typed then next clip"
    m.load(next)
    m.flushAndWait()
    check("typed Title survives ⌘] / ‹ › (load)", (try? store.video(id: start))??.title == "Typed then next clip")
    check("next clip starts without the draft", m.titleDraft == nil && m.videoId == next)
    // Typed title, then Done / ⌘↩: EditorView.done() = flushAndWait().
    m.titleDraft = "Typed then Done"
    m.flushAndWait()
    check("typed Title survives Done / ⌘↩ (flushAndWait)", (try? store.video(id: next))??.title == "Typed then Done")
    m.load(third)
    // No-op clicks store nothing.
    m.setVersionField(\.style, \.style, m.resolved.style)
    check("clicking the default style stays Default", m.resolved.isDefault("style"))
    m.setVersionField(\.align, \.align, m.resolved.align)
    check("clicking the default alignment stays Default", m.resolved.isDefault("align"))
    m.setVersionField(\.size, \.size, m.resolved.size)
    check("dragging size back to the default stays Default", m.resolved.isDefault("size"))
    let sets = m.resolved.hashtagSetIds
    if let extra = m.sets.first(where: { !sets.contains($0.id) }) {
      m.setHashtagSets(sets + [extra.id])
      check("adding a hashtag group is Custom", !m.resolved.isDefault("hashtagSetIds"))
      m.setHashtagSets(sets)
      check("removing it again is Default", m.resolved.isDefault("hashtagSetIds"))
    }
    m.setCaptionTemplate(m.defaults.captionTemplateId)
    check("choosing the default template stays Default", m.resolved.isDefault("captionTemplateId"))
    m.setExtraHashtags(["#a"]); m.resetVersion(["hashtagSetIds", "extraHashtags"])
    check("hashtag reset clears extra hashtags", m.resolved.extraHashtags == m.defaults.extraHashtags)
    // Clearing the text field is an explicit empty, not the Title again; "Follow the Title" resets.
    m.setTitle("Some title")
    m.setText("typed")
    m.setText("")
    check("cleared text stays empty (no Title refill)", m.resolved.text.isEmpty && !m.resolved.isDefault("text"))
    // Round 25: a Return or a space typed into the emptied box stays as typed (it brought the Title back).
    for blank in ["\n", " "] {
      m.setText(blank)
      check("blank typed text \(blank.debugDescription) stays typed, No text off",
            m.resolved.text == blank && !m.resolved.isDefault("text") && !m.resolved.noText && !m.resolved.hasText)
    }
    m.resetVersion(["text"])
    check("Follow the Title restores the default", m.resolved.isDefault("text") && m.resolved.text == "Some title")
    m.setNoText(true); m.setNoText(false)
    check("No text on → off follows the Title again", m.resolved.isDefault("text") && m.resolved.text == "Some title")
    // Round 7 (C1): a held clip puts no dot on Caption, and the chip says to use Send to Queue.
    try? store.setHeldInEdit(third, true)
    m.load(third)
    let flagged = Set(m.liveIssues.compactMap { EditorModel.section(for: $0.kind) })
    check("held clip: issue listed", m.liveIssues.contains { $0.kind == .heldInEdit })
    check("held clip: no warning dot on Caption", !flagged.contains(.caption) || !m.captionIssues.isEmpty || !m.captionWarnings.isEmpty)
    let help = EditorHeader(model: m, videoIds: ids, done: {}).chipHelp(m.liveIssues, target: m.liveIssues.first { EditorModel.section(for: $0.kind) != nil },
                                                                         held: m.liveIssues.first { $0.kind == .heldInEdit })
    print("editor-selftest: chip tooltip “\(help)”")
    check("held clip: chip tooltip names Send to Queue", help.contains("Send to Queue"))
    try? store.setHeldInEdit(third, false)
    m.load(third)
    // Round 7 (C4): WYSIWYG caption.
    try? store.save(HashtagSet(id: "st-g", name: "G", category: "My groups", tags: ["#g1", "#g2"], sort: 0))
    m.load(third)
    m.resetVersion(["caption", "hashtagSetIds", "extraHashtags", "captionTemplateId"])
    check("field shows the template's caption", !m.captionIsWritten && m.mainCaption == m.caption(for: .tiktok))
    m.setHashtagSets(["st-g"])
    check("a group goes into the template caption", m.mainCaption.contains("#g1 #g2"))
    m.typeCaption("Mine\n#g1 #g2"); m.commitCaptionDraft()
    check("typing makes it Custom, literally", m.captionIsWritten && m.mainCaption == "Mine\n#g1 #g2")
    m.setExtraHashtags(["#x", "#g1"])
    check("extra tags swap in place without duplicates", m.mainCaption == "Mine\n#g1 #g2 #x")
    m.setHashtagSets([])
    check("turning the group off takes its tags out", m.mainCaption == "Mine\n#x #g1")
    m.setCaptionTemplate("short")
    check("choosing a template rewrites the caption", !m.captionIsWritten && m.mainCaption.hasSuffix("#x #g1"))
    m.undo()
    check("⌘Z brings the written caption back", m.captionIsWritten && m.mainCaption == "Mine\n#x #g1")
    m.resetCaptionToTemplate()
    check("↺ goes back to the template", !m.captionIsWritten)
    // Round 7 (C5): YouTube title.
    let tplTitle = m.youtubeTitle
    m.typeYouTubeTitle("Typed title")
    check("typing the YouTube title makes it Custom", m.resolved.youtubeTitle == "Typed title" && m.youtubeTitle == "Typed title")
    m.typeYouTubeTitle(tplTitle)
    check("typing the template's title back follows the template", m.resolved.youtubeTitle.isEmpty)
    // v0.8.1: a hashtag group made from the editor.
    for g in (try? store.hashtagSets()) ?? [] { try? store.deleteHashtagSet(g.id) }
    m.load(third)
    m.resetVersion(["caption", "hashtagSetIds", "extraHashtags", "captionTemplateId"])
    m.openGroupForm()
    check("form opens", m.groupForm != nil && m.groupForm?.editing == nil)
    check("blank form doesn't save", !m.saveGroup(name: "  ", tags: "#a") && !m.saveGroup(name: "Blank", tags: " # ") && m.groupForm != nil)
    m.typeCaption("Typed, not applied yet")
    check("New group saves", m.saveGroup(name: " Piano ", tags: "Amapiano, #PIANO piano"))
    let made = (try? store.hashtagSets())?.first { $0.name == "Piano" }
    check("group is in the shared store, normalised", made?.tags == ["#amapiano", "#piano"])
    check("form closes", m.groupForm == nil)
    check("group is on for this clip", made.map { m.resolved.hashtagSetIds.contains($0.id) } == true)
    check("typed text kept, tags added in place", m.mainCaption == "Typed, not applied yet\n#amapiano #piano")
    m.undo()
    check("⌘Z takes the group off, keeps the text", m.mainCaption == "Typed, not applied yet" && m.sets.contains { $0.name == "Piano" })
    m.redo()
    check("⇧⌘Z puts it back", m.mainCaption == "Typed, not applied yet\n#amapiano #piano")
    m.openGroupForm()
    check("duplicate name doesn't save", !m.saveGroup(name: "PIANO", tags: "#x") && ((try? store.hashtagSets()) ?? []).count == 1)
    m.groupForm = nil
    m.setExtraHashtags(["#piano"])
    check("no tag twice in the caption", Captions.tags(in: m.mainCaption).filter { $0 == "#piano" }.count == 1)
    m.setExtraHashtags([])
    if let made {
      m.openGroupForm(made)
      check("edit form is filled in", m.groupForm?.name == "Piano" && m.groupForm?.tags == "#amapiano #piano")
      check("editing keeps its own name", m.saveGroup(name: "Piano", tags: "#amapiano #yanos"))
      check("edit swaps the tags in this clip's written caption", m.mainCaption == "Typed, not applied yet\n#amapiano #yanos")
      // Review F6: deleted while its edit form is open → Save doesn't bring it back.
      m.openGroupForm(m.sets.first)
      try? store.deleteHashtagSet(made.id)
      check("a group deleted meanwhile isn't brought back", !m.saveGroup(name: "Piano", tags: "#amapiano")
            && m.groupForm == nil && ((try? store.hashtagSets()) ?? []).isEmpty)
      // Review F2: this clip has a scheduled post, so an edit keeps its caption and history starts over.
      m.resetVersion(["caption", "hashtagSetIds", "extraHashtags", "captionTemplateId"])
      m.openGroupForm()
      _ = m.saveGroup(name: "Scheduled", tags: "#one #two")
      m.flushAndWait()
      _ = try? store.db.run("""
        INSERT INTO platform_posts(id,video_id,platform,version_no,attempt_no,kind,scheduled_at,state,publisher,created_at,updated_at)
        VALUES('selftest-post',?,'x',1,1,'regular',0,'planned','manual',0,0)
        """, [third])
      let frozen = m.mainCaption
      if let g = m.sets.first(where: { $0.name == "Scheduled" }) {
        m.openGroupForm(g)
        check("edit form counts the clip with posts", m.groupForm?.impact?.kept == 1)
        check("edit saves", m.saveGroup(name: "Scheduled", tags: "#one #three"))
        check("the scheduled clip's caption is byte-identical", m.mainCaption == frozen && frozen.hasSuffix("#one #two"))
        check("its tags are frozen, the chip is off", m.resolved.hashtagSetIds.isEmpty && m.resolved.extraHashtags == ["#one", "#two"])
        check("history starts over after a freeze", !m.canUndo)
      }
      _ = try? store.db.run("DELETE FROM platform_posts WHERE id='selftest-post'")
    }
    m.resetVersion(["caption", "hashtagSetIds", "extraHashtags", "captionTemplateId"])
    m.flushAndWait()
    print("editor-selftest: \(failures == 0 ? "all passed" : "\(failures) failed")")
    return failures == 0 ? 0 : 1
  }

  /// Opens the real editor (live AVPlayer) in a backstage window for `seconds`, printing its window number.
  private static func live(store: Store, video: String, ids: [String], seconds: Double) async -> Int32 {
    let window = SnapshotWindow.make(NSRect(x: 0, y: 0, width: 1440, height: 900),
                                     [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.title = "DJ Queue — Editor (dev)"
    let env = ProcessInfo.processInfo.environment
    let model = EditorModel(store: store, videoId: video)
    window.contentView = NSHostingView(rootView: EditorView(model: model, videoIds: ids, onDone: {}))
    window.isReleasedWhenClosed = false
    if let a = env["DJQ_EDITOR_LIVE_APPEARANCE"] { window.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
    // Off every display, like every other run: nothing here shows on the screen or takes focus.
    Backstage.show(window)
    window.makeKey()
    // `DJQ_EDITOR_LIVE_SECTIONS=<dir>`: one window-server capture per inspector section (`live-<section>.png`).
    if let dir = env["DJQ_EDITOR_LIVE_SECTIONS"] {
      print("editor-live: window \(window.windowNumber)")
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? await Task.sleep(for: .seconds(6))
      for s in EditorSection.inspector(photo: false) {
        model.scrollTarget = s
        try? await Task.sleep(for: .seconds(1.5))
        let file = (dir as NSString).appendingPathComponent("live-\(s.rawValue.lowercased()).png")
        if let data = WindowCapture.png(window) {
          try? data.write(to: URL(fileURLWithPath: file))
          print("editor-live: captured \(file)")
        } else {
          print("editor-live: window capture unavailable")
        }
      }
      fflush(stdout)
      window.close()
      return 0
    }
    print("editor-live: window \(window.windowNumber)")
    fflush(stdout)
    // Optional in-process capture of our own window (window-server image: shows the live player frame; needs no
    // Screen Recording permission) — `DJQ_EDITOR_LIVE_PNG=<file>`, taken after 8 s.
    if let png = ProcessInfo.processInfo.environment["DJQ_EDITOR_LIVE_PNG"] {
      try? await Task.sleep(for: .seconds(8))
      let fr = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
      print("editor-live: first responder \(fr) (text field focused: \(window.firstResponder is NSTextView))")
      if let data = WindowCapture.png(window) {
        try? data.write(to: URL(fileURLWithPath: png))
        print("editor-live: captured \(png)")
      } else {
        print("editor-live: window capture unavailable")
        window.close()
        return 1
      }
      // The window server returns a blank image while the display sleeps, so also let AppKit draw the live view tree
      // (the live player layer doesn't draw this way; everything else is the real, non-snapshot editor).
      if let view = window.contentView {
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
          view.cacheDisplay(in: view.bounds, to: rep)
          let viewPNG = png.replacingOccurrences(of: ".png", with: "-view.png")
          try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: viewPNG))
          print("editor-live: drew \(viewPNG)")
        }
      }
      fflush(stdout)
    }
    try? await Task.sleep(for: .seconds(seconds))
    window.close()
    return 0
  }
}
