import Foundation

/// The Settings pane a search result opens. Raw values match `SettingsSection` in the app.
public enum SettingsPane: String, CaseIterable, Sendable {
  case general, platforms, publishing, schedule, queue, newClipDefaults, captions, rendering, playback, alerts, engine

  public var title: String {
    switch self {
    case .general: "General"
    case .platforms: "Platforms"
    case .publishing: "Publishing"
    case .schedule: "Schedule"
    case .queue: "Queue"
    case .newClipDefaults: "New clip defaults"
    case .captions: "Captions & titles"
    case .rendering: "Rendering"
    case .playback: "Playback & autoplay"
    case .alerts: "Alerts"
    case .engine: "Engine"
    }
  }
}

/// Anchor ids shared by the registry and the Settings views (`.settingsAnchor`).
public enum SettingsAnchor {
  public static func row(_ label: String) -> String { "row:\(label)" }
  public static func group(_ title: String) -> String { "group:\(title)" }
  public static func hashtagGroup(_ id: String) -> String { "hashtag:\(id)" }
  public static func captionTemplate(_ id: String) -> String { "template:\(id)" }
  public static func titleTemplate(_ id: String) -> String { "title:\(id)" }
}

/// One searchable place in Settings.
public struct SettingsSearchEntry: Sendable, Hashable {
  public var pane: SettingsPane
  public var group: String?
  /// What the result reads. Differs from the row's own label for per-platform rows ("TikTok slot time").
  public var title: String
  public var description: String?
  public var anchor: String
  /// Tells apart entries that land on the same anchor ("TikTok limits", "X limits").
  public var variant: String? = nil
  /// The row is only drawn while this platform is on (Schedule, Queue).
  public var activeOnly: Platform? = nil

  /// Is the row in the pane right now? A result must land on something.
  public func isDrawn(_ settings: Settings) -> Bool { activeOnly.map(settings.activePlatforms.contains) ?? true }

  public var id: String { "\(pane.rawValue).\(anchor)" + (variant.map { "#\($0)" } ?? "") }

  static func row(_ p: SettingsPane, _ label: String, group: String? = nil, description: String? = nil, title: String? = nil,
                  activeOnly: Platform? = nil) -> Self {
    Self(pane: p, group: group, title: title ?? label, description: description, anchor: SettingsAnchor.row(label), activeOnly: activeOnly)
  }

  static func group(_ p: SettingsPane, _ title: String, description: String? = nil) -> Self {
    Self(pane: p, group: nil, title: title, description: description, anchor: SettingsAnchor.group(title))
  }
}

/// Every Settings row and group header, by pane. `SettingsRegistryTests` scans Sources/DJQueueApp/Settings and fails
/// when a literal `SettingsRow("…")` or `SettingsGroupHeader("…")` is missing here, sits in another pane, or carries
/// another description. Rows built per platform are added in `perPlatform`.
public enum SettingsSearchRegistry {
  public static let all: [SettingsSearchEntry] = fixed + perPlatform + extras

  public static let fixed: [SettingsSearchEntry] = [
    // general
    .row(.general, "Pause all posting", description: "Nothing is handed to you or posted until you turn this off. The plan stays as it is."),
    .row(.general, "Posts per day", description: "Each clip goes to every platform it posts to."),
    .row(.general, "Time zone", description: "Slot times, days and reminders use this zone."),
    .row(.general, "Week starts on", description: "First day of the Week screen and of each approval."),
    // platforms
    .group(.platforms, "Limits", description: "Used by validation (“Too long for X”) and the caption counters."),
    .group(.platforms, "Publishing"),
    .row(.platforms, "Who posts", group: "Publishing", description: "Manual or Postiz for each platform."),
    // publishing
    .group(.publishing, "Postiz", description: "Postiz posts for you at each slot, even with the Mac off."),
    .row(.publishing, "Test run", group: "Postiz", description: "TikTok goes to your inbox, YouTube is unlisted, Instagram, Facebook, Threads and X are saved as Postiz drafts."),
    .row(.publishing, "Connection", group: "Postiz", description: "Whether Postiz answers and when it was last checked."),
    .row(.publishing, "Postiz API key", group: "Postiz", description: "The key that lets DJ Queue talk to Postiz."),
    .group(.publishing, "Platforms", description: "Who posts each platform, the Postiz channel it uses and its options."),
    // schedule
    .group(.schedule, "Slot times", description: "When each platform's post is due every day."),
    .group(.schedule, "Posting"),
    .row(.schedule, "Second post offset", group: "Posting", description: "Extra posts on the same day use the same slots, shifted by this much."),
    .row(.schedule, "Post early", group: "Posting", description: "Allow posting any time on the day, before the slot."),
    .row(.schedule, "Late grace", group: "Posting", description: "A post is still due this long after its slot; after that the plan shifts."),
    .row(.schedule, "Retry stagger", group: "Posting", description: "Re-queued failures post this long after the day's slot."),
    .row(.schedule, "Repost cooldown", group: "Posting", description: "Days before the same clip can post again on a platform."),
    // queue
    .row(.queue, "Order", description: "Orders the unplanned backlog by score. Planned days don't move."),
    .row(.queue, "Ties", description: "Equal scores: older session first, then the night's order (part, start)."),
    .group(.queue, "Order per platform", description: "Give one platform its own order."),
    .group(.queue, "Spacing"),
    .row(.queue, "Avoid overlapping clips", group: "Spacing", description: "Keep clips from the same part of a set apart. Off: your scores decide."),
    .row(.queue, "Keep apart for", group: "Spacing", description: "Minimum days between overlapping clips."),
    // newClipDefaults
    .group(.newClipDefaults, "Frame", description: "Default framing for clips you haven't cropped. Each crop is still confirmed per clip."),
    .row(.newClipDefaults, "Aspect", group: "Frame", description: "Shape of the posted video."),
    .row(.newClipDefaults, "Crop position", group: "Frame", description: "Where the default crop sits on a wide picture."),
    .group(.newClipDefaults, "Trim", description: "Default start and end of a clip."),
    .row(.newClipDefaults, "Start and end", group: "Trim", description: "Clips without markers always use the whole file."),
    .row(.newClipDefaults, "Extra seconds before", group: "Trim", description: "Starts this much before the in-marker."),
    .row(.newClipDefaults, "Extra seconds after", group: "Trim", description: "Ends this much after the out-marker."),
    .group(.newClipDefaults, "Text", description: "Default overlay text on the video."),
    .row(.newClipDefaults, "Style", group: "Text"),
    .row(.newClipDefaults, "Size", group: "Text", description: "Points on a 1080-wide frame."),
    .row(.newClipDefaults, "Vertical position", group: "Text", description: "Each clip can still be dragged in the editor."),
    .row(.newClipDefaults, "Horizontal position", group: "Text"),
    .row(.newClipDefaults, "Alignment", group: "Text"),
    .row(.newClipDefaults, "Show text", group: "Text", description: "For the whole clip or only at the start."),
    .row(.newClipDefaults, "First seconds", group: "Text", description: "How long the text shows at the start."),
    .row(.newClipDefaults, "Text comes from", group: "Text", description: "Used until you type text for a clip. Never rewritten."),
    .row(.newClipDefaults, "No text for Talking clips", group: "Text", description: "Talking clips start without overlay text."),
    .group(.newClipDefaults, "Cover", description: "Default cover image for each post."),
    .row(.newClipDefaults, "Include text on cover", group: "Cover", description: "The overlay text is drawn on the cover too."),
    .row(.newClipDefaults, "Cover frame", group: "Cover"),
    .row(.newClipDefaults, "Seconds into the trim", group: "Cover", description: "Where the cover frame is taken."),
    .group(.newClipDefaults, "Caption", description: "Default caption and YouTube title. Templates, hashtag groups and title templates live in Captions & titles."),
    .row(.newClipDefaults, "Caption template", group: "Caption"),
    .row(.newClipDefaults, "Hashtag groups", group: "Caption", description: "Groups every new clip starts with (none = no hashtags). Filled into {hashtags}."),
    .row(.newClipDefaults, "Extra hashtags", group: "Caption", description: "Added after the groups, separated by spaces."),
    .row(.newClipDefaults, "YouTube title template", group: "Caption", description: "The title template new clips use. Edit the templates in Captions & titles."),
    .group(.newClipDefaults, "Caption template per platform", description: "Default template for one platform when the clip didn't choose one."),
    .group(.newClipDefaults, "Posting", description: "Default platforms for a new clip. A clip can still turn one on or off in the editor."),
    .row(.newClipDefaults, "Post to", group: "Posting", description: "Only platforms that are on in Platforms get posts."),
    .row(.newClipDefaults, "Safe zones shown", group: "Posting", description: "Platform overlays the editor shows on the preview."),
    .group(.newClipDefaults, "Kind"),
    .row(.newClipDefaults, "Kind", group: "Kind", description: "videos.json content-type: talking still wins."),
    // captions
    .group(.captions, "Hashtag groups", description: "Your own groups. A clip has no hashtags until you pick a group in the editor (or set default groups in New clip defaults); extra hashtags can always be added per clip."),
    .group(.captions, "YouTube title templates", description: "{text} = the clip's overlay text, else its title, else the raw marker tag. Over YouTube's limit only {text} is shortened. In the editor, pick one and then edit the title freely."),
    .group(.captions, "Caption templates", description: "{text} overlay text on one line · {title} the clip's title · {set} session name · {link} the link line · {tag} raw marker tag · {hashtags} the clip's hashtags. \(CaptionTemplates.hashtagHint)."),
    .row(.captions, "Link line", group: "Caption templates", description: "What {link} fills in and the editor's Link chip adds. Clips with scheduled or posted posts keep their captions."),
    .group(.captions, "Titles"),
    .row(.captions, "Where titles come from", group: "Titles", description: "videos.json (title, title_suggestions) or an agent running djq title / djq suggest. The app never makes titles up."),
    .row(.captions, "Ask an agent", group: "Titles", description: "Copies a prompt with each clip's tag, set position and the exact djq command. Suggestions appear in the editor."),
    // rendering
    .group(.rendering, "Audio"),
    .row(.rendering, "Loudness target", group: "Audio", description: "Integrated loudness every render is normalised to."),
    .row(.rendering, "True peak", group: "Audio", description: "Ceiling for the loudest sample."),
    .row(.rendering, "Loudness range", group: "Audio", description: "How much the loudness may vary across the clip."),
    .group(.rendering, "Video"),
    .row(.rendering, "Bitrate", group: "Video", description: "Video bitrate of every render."),
    .row(.rendering, "Render ahead", group: "Video", description: "Approved posts are rendered this far ahead."),
    .group(.rendering, "Posted renders"),
    .row(.rendering, "Cleanup", group: "Posted renders", description: "What happens to a render once every platform has posted it."),
    .row(.rendering, "Delete after", group: "Posted renders", description: "Days after the last platform posted."),
    // playback
    .row(.playback, "Autoplay previews", description: "Visible clips play muted from small preview copies made in the background."),
    .row(.playback, "Unmute on hover", description: "Hovering a clip plays it with sound (one clip at a time); moving away mutes it again. Previews never unmute by themselves."),
    .row(.playback, "Grids: play on hover only", description: "Grid views show covers; a tile plays only while the pointer is on it."),
    .row(.playback, "Which clips play", description: "Cards, List and Single views: all visible clips play, at most 4 at once."),
    .row(.playback, "Loop", description: "The trim is what will post; the whole file shows everything around it."),
    // alerts
    .group(.alerts, "Runway"),
    .row(.alerts, "Approve next week", group: "Runway", description: "Card and notification when approved runway drops below this."),
    .row(.alerts, "Record a new set", group: "Runway", description: "Card and notification when total runway drops below this."),
    .group(.alerts, "Reminders"),
    .row(.alerts, "Approval reminder", group: "Reminders", description: "Notification if next week isn't approved by then."),
    .row(.alerts, "Slot reminders", group: "Reminders", description: "One notification per slot; silent when it's already posted."),
    .row(.alerts, "Copyright and failed posts", group: "Reminders", description: "Red card on every screen and a red badge on the menu-bar icon."),
    // engine
    .group(.engine, "Background engine"),
    .row(.engine, "Run at login", group: "Background engine", description: "Starts DJ Queue at login; the engine keeps running with the window closed."),
    .row(.engine, "Engine", group: "Background engine", description: "Is the engine running, and its last tick."),
    .row(.engine, "Wake before first slot", group: "Background engine", description: "Schedules a Mac wake with pmset (needs an admin password)."),
    .row(.engine, "Engine log", group: "Background engine", description: "The engine's log file."),
    .group(.engine, "Folders"),
    .row(.engine, "DJ Video", group: "Folders", description: "Show this folder in Finder."),
    .row(.engine, "App data", group: "Folders", description: "Show this folder in Finder."),
    .row(.engine, "Logs", group: "Folders", description: "Show this folder in Finder."),
    .row(.engine, "Backups", group: "Folders", description: "Show this folder in Finder."),
    .group(.engine, "Backups"),
    .row(.engine, "Daily backup", group: "Backups", description: "Keeps 14 copies of the database."),
    .group(.engine, "Auto-update"),
    .row(.engine, "Install updates from main", group: "Auto-update", description: "Builds and tests each new commit on main, backs up your data, then installs it when the window is closed."),
    .row(.engine, "Update log", group: "Auto-update", description: "Every check, install and block is logged. To go back to the previous build, run djq autoupdate rollback in Terminal."),
  ]

  /// Rows whose label is computed: the row passes this anchor itself.
  static let extras: [SettingsSearchEntry] = [
    .row(.engine, "Installed build", group: "Auto-update", description: "What's installed and what the last update did."),
  ]

  /// Rows the views build from `Platform.allCases`.
  public static let perPlatform: [SettingsSearchEntry] = Platform.allCases.sorted().flatMap { p -> [SettingsSearchEntry] in
    let n = p.displayName
    return [
      .row(.platforms, n, description: "Turn it on, pause it or turn it off.", title: "\(n) on or off"),
      SettingsSearchEntry(pane: .platforms, group: "Limits", title: "\(n) limits", description: "Longest clip, largest file, caption and title length.",
                          anchor: SettingsAnchor.group("Limits"), variant: p.rawValue),
      .row(.publishing, n, group: "Platforms", description: "Manual or Postiz, its channel and its options.", title: "\(n) publishing"),
      .row(.schedule, n, group: "Slot times", description: "When its post is due every day.", title: "\(n) slot time", activeOnly: p),
      .row(.queue, n, group: "Order per platform", description: "Give it its own order.", title: "\(n) order", activeOnly: p),
      .row(.newClipDefaults, n, group: "Caption template per platform", description: "Default template when the clip didn't choose one.",
           title: "\(n) caption template"),
    ]
  }

  public static func entry(id: String) -> SettingsSearchEntry? { byId[id] }

  private static let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
}
