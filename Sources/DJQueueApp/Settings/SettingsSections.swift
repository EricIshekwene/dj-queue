import AppKit
import DJQCore
import SwiftUI

// Immediate-apply sections: every change saves at once through `model.update { … }`.

// MARK: General

struct GeneralSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsRow("Pause all posting", description: "Nothing is handed to you or posted until you turn this off. The plan stays as it is.") {
      DSSwitch(isOn: Binding(get: { model.settings.paused }, set: { model.setPaused($0) }))
        .accessibilityLabel("Pause all posting")
    }
    SettingsRow("Posts per day", description: "Each clip goes to every platform it posts to.") {
      DSXStepper(label: "Posts per day", int: model.binding(\.postsPerDay) { "Posts per day set to \($0)" }, range: 1...5,
                 less: "Post fewer clips each day", more: "Post more clips each day") { "\($0) per day" }
    }
    SettingsRow("Time zone", description: "Slot times, days and reminders use this zone.") {
      SettingsSelect(label: "Time zone", selection: model.binding(\.timeZone) { "Time zone set to \($0)" }, options: timeZones)
    }
    SettingsRow("Week starts on", description: "First day of the Calendar.") {
      SettingsSelect(label: "Week starts on", selection: model.binding(\.weekStartsOn) { "Week now starts on \(SettingsFmt.weekday($0))" },
                     options: [DSSelectOption(value: 2, title: "Monday"), DSSelectOption(value: 1, title: "Sunday")])
    }
  }

  private var timeZones: [DSSelectOption<String>] {
    var ids = ["America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "Europe/London",
               "Europe/Paris", "Africa/Johannesburg", "Africa/Lagos"]
    for extra in [TimeZone.current.identifier, model.settings.timeZone] where !ids.contains(extra) { ids.insert(extra, at: 0) }
    return ids.map { id in
      let tz = TimeZone(identifier: id)
      let name = tz?.localizedName(for: .generic, locale: Locale(identifier: "en_US")) ?? id
      return DSSelectOption(value: id, title: name, detail: id)
    }
  }
}

// MARK: Platforms

struct PlatformsSettings: View {
  @Bindable var model: AppModel

  private enum Mode: String { case on, paused, off }

  var body: some View {
    ForEach(Platform.allCases.sorted()) { p in
      SettingsRow(p.displayName, description: description(p), platform: p) {
        SettingsSelect(label: "\(p.displayName) posting", selection: modeBinding(p), options: [
          DSSelectOption(value: Mode.on, title: "On"),
          DSSelectOption(value: Mode.paused, title: "Paused"),
          DSSelectOption(value: Mode.off, title: "Off"),
        ])
      }
    }
    SettingsNote("Paused keeps the platform's posts planned but doesn't hand them to you. Off plans nothing for it.")

    SettingsGroupHeader("Limits", description: "Used by validation (“Too long for X”) and the caption counters.")
    limitsTable

    SettingsGroupHeader("Publishing")
    SettingsRow("Who posts", description: publishingSummary) {
      DSButton("Open Publishing", trailingIcon: "chevron.right", variant: .ghost, size: .sm,
               tooltip: "Set Manual or Postiz per platform") { model.settingsSection = .publishing }
    }
  }

  private var publishingSummary: String {
    let n = model.settings.publishing.postizPlatforms.count
    let test = model.settings.publishing.testMode ? " · Test run on" : ""
    return (n == 0 ? "Every platform is Manual: you post from the Calendar." : "\(n) of 6 through Postiz, the rest Manual.") + test
  }

  private func description(_ p: Platform) -> String {
    let time = SettingsFmt.time(model.settings.slot(for: p))
    let host = p.uploadURL.host ?? ""
    return model.settings.enabledPlatforms.contains(p) ? "Posts at \(time) · \(host)" : "Not planned · \(host)"
  }

  private func modeBinding(_ p: Platform) -> Binding<Mode> {
    Binding(get: {
      !model.settings.enabledPlatforms.contains(p) ? .off : model.settings.pausedPlatforms.contains(p) ? .paused : .on
    }, set: { m in
      model.update("\(p.displayName) \(m == .on ? "turned on" : m == .paused ? "paused" : "turned off")") { s in
        switch m {
        case .on: s.enabledPlatforms.insert(p); s.pausedPlatforms.remove(p)
        case .paused: s.enabledPlatforms.insert(p); s.pausedPlatforms.insert(p)
        case .off: s.enabledPlatforms.remove(p); s.pausedPlatforms.remove(p)
        }
      }
    })
  }

  private var limitsTable: some View {
    VStack(spacing: 0) {
      HStack(spacing: DS.space.xs) {
        Text("Platform").frame(maxWidth: .infinity, alignment: .leading)
        Text("Length (s)").frame(width: 76, alignment: .trailing)
        Text("Size (MB)").frame(width: 76, alignment: .trailing)
        Text("Caption").frame(width: 76, alignment: .trailing)
        Text("Hashtags").frame(width: 76, alignment: .trailing)
          .dsTooltip("Most hashtags a caption posts there. The first ones in the caption stay. Blank = no cap")
        Text("Title").frame(width: 76, alignment: .trailing)
      }
      .font(DS.type.captionMedium)
      .foregroundStyle(DS.color.textSecondary)
      .frame(height: 32)
      .overlay(alignment: .bottom) { DSSeparator() }
      ForEach(Platform.allCases.sorted()) { p in
        HStack(spacing: DS.space.xs) {
          DSPlatformIcon(platform: p, size: 22, showsLabel: true).frame(maxWidth: .infinity, alignment: .leading)
          field("\(p.displayName) maximum length in seconds", "Set \(p.displayName)'s longest clip (seconds)",
                limit(p).map { Int($0.maxDuration) }) { v in
            setLimit(p, "\(p.displayName) length limit set to \(v) s") { $0.maxDuration = Double(v) }
          }
          field("\(p.displayName) maximum size in MB", "Set \(p.displayName)'s largest file (MB)",
                limit(p).map { Int($0.maxBytes / 1_000_000) }) { v in
            setLimit(p, "\(p.displayName) size limit set to \(v) MB") { $0.maxBytes = Int64(v) * 1_000_000 }
          }
          field("\(p.displayName) caption characters", "Set \(p.displayName)'s caption limit (characters)",
                limit(p)?.captionLimit) { v in
            setLimit(p, "\(p.displayName) caption limit set to \(v)") { $0.captionLimit = v }
          }
          SettingsOptionalNumberField(label: "\(p.displayName) hashtag cap", value: limit(p)?.maxHashtags,
                                      tooltip: "Set how many hashtags \(p.displayName) keeps, first ones first. Blank = no cap") { v in
            model.saveHashtagCap(v, for: p)
          }
          .frame(width: 76)
          if p == .youtube || p == .tiktok {
            field("\(p.displayName) title characters", "Set the \(p.displayName) title limit (at most \(titleMax(p)))", limit(p)?.titleLimit) { v in
              // The platform's own cap is the ceiling (YouTube 100, TikTok 90): a higher value would let a title pass
              // here that Postiz then cuts.
              let c = min(v, titleMax(p))
              setLimit(p, c < v ? "\(p.displayName) allows \(c) at most — title limit set to \(c)" : "\(p.displayName) title limit set to \(c)") { $0.titleLimit = c }
            }
          } else {
            Text("—").font(DS.type.callout).foregroundStyle(DS.color.textTertiary).frame(width: 76, alignment: .trailing)
              .dsTooltip("Only YouTube and TikTok have a title")
          }
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) { DSSeparator() }
      }
    }
  }

  /// Saves on ↩ or when the field loses focus (never mid-typing).
  private func field(_ label: String, _ tooltip: String, _ value: Int?, _ set: @escaping (Int) -> Void) -> some View {
    SettingsNumberField(label: label, value: value ?? 0, tooltip: tooltip, commit: set).frame(width: 76)
  }

  private func titleMax(_ p: Platform) -> Int { p == .tiktok ? PostizPayload.tiktokTitleMax : PostizPayload.youtubeTitleMax }

  private func limit(_ p: Platform) -> PlatformLimits? { model.settings.limits[p] ?? PlatformLimits.defaults[p] }

  private func setLimit(_ p: Platform, _ label: String, _ change: @escaping (inout PlatformLimits) -> Void) {
    model.update(label) { s in
      guard var l = s.limits[p] ?? PlatformLimits.defaults[p] else { return }
      change(&l)
      s.limits[p] = l
    }
  }
}

// MARK: Schedule

struct ScheduleSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsGroupHeader("Slot times", description: "When each platform's post is due every day.", first: true)
    if model.settings.activePlatforms.isEmpty {
      SettingsNote("Every platform is off. Turn one on in Platforms.")
    }
    ForEach(model.settings.activePlatforms) { p in
      SettingsRow(p.displayName, description: p == .youtube ? YouTubeWindow.settingsNote : nil, platform: p) {
        SettingsSelect(label: "\(p.displayName) slot time", selection: slotBinding(p),
                       options: SettingsFmt.timeOptions(current: model.settings.slot(for: p)))
      }
    }
    HStack {
      Spacer()
      DSButton("Reset slot times", icon: "arrow.counterclockwise", variant: .ghost, size: .sm,
               disabledReason: slotsAreDefault ? "Slot times are already the built-in times" : nil,
               tooltip: "Put every slot back to its built-in time") {
        model.update("Slot times reset") { s in for p in Platform.allCases { s.slotMinutes[p] = p.defaultSlotMinutes } }
      }
    }
    .padding(.top, DS.space.xs)

    SettingsGroupHeader("Posting")
    SettingsRow("Second post offset", description: "Extra posts on the same day use the same slots, shifted by this much.",
                disabledReason: model.settings.postsPerDay < 2 ? "Only used with 2 or more posts per day (General)." : nil) {
      DSXStepper(label: "Second post offset", int: Binding(get: { model.settings.secondPostOffsetMinutes / 60 },
                                                           set: { v in model.update("Second post offset set to +\(v) h") { $0.secondPostOffsetMinutes = v * 60 } }),
                 range: 1...6) { "+\($0) h" }
    }
    SettingsRow("Post early", description: "Allow posting any time on the day, before the slot.") {
      DSSwitch(isOn: model.toggleBinding(\.allowEarlyPosting, "Post early")).accessibilityLabel("Post early")
    }
    SettingsRow("Late grace", description: "A post is still due this long after its slot; after that the plan shifts.") {
      DSXStepper(label: "Late grace", value: model.binding(\.lateGraceHours) { "Late grace set to \(SettingsFmt.hours($0))" },
                 range: 1...12, format: SettingsFmt.hours)
    }
    SettingsRow("Retry stagger", description: "Re-queued failures post this long after the day's slot.") {
      DSXStepper(label: "Retry stagger", value: model.binding(\.retryStaggerHours) { "Retry stagger set to \(SettingsFmt.hours($0))" },
                 range: 1...8, less: "Retry failed posts sooner after the slot", more: "Retry failed posts later after the slot",
                 format: SettingsFmt.hours)
    }
    SettingsRow("Repost cooldown", description: "Days before the same clip can post again on a platform.") {
      DSXStepper(label: "Repost cooldown", int: model.binding(\.repostCooldownDays) { "Repost cooldown set to \(SettingsFmt.days($0))" },
                 range: 1...90, format: SettingsFmt.days)
    }
  }

  private var slotsAreDefault: Bool { Platform.allCases.allSatisfy { model.settings.slot(for: $0) == $0.defaultSlotMinutes } }

  private func slotBinding(_ p: Platform) -> Binding<Int> {
    Binding(get: { model.settings.slot(for: p) },
            set: { v in model.update("\(p.displayName) slot set to \(SettingsFmt.time(v))") { $0.slotMinutes[p] = v } })
  }
}

// MARK: Queue

struct QueueSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsRow("Order", description: "Orders the Queue by score. A change re-lays the calendar; pinned days stay.") {
      SettingsSelect(label: "Order", selection: model.binding(\.sort) { "Order set to \($0.displayName)" },
                     options: SortDirection.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
    }
    SettingsRow("Ties", description: "Equal scores: older session first, then the night's order (part, start).") {
      Text("Older first").font(DS.type.callout).foregroundStyle(DS.color.textSecondary).padding(.trailing, DS.space.sm)
    }

    SettingsGroupHeader("Order per platform", description: "Give one platform its own order.")
    ForEach(model.settings.activePlatforms) { p in
      SettingsRow(p.displayName, platform: p) {
        SettingsSelect(label: "\(p.displayName) order", selection: overrideBinding(p), options:
          [DSSelectOption(value: SortDirection?.none, title: "Same as Order")]
            + SortDirection.allCases.map { DSSelectOption(value: SortDirection?.some($0), title: $0.displayName) })
      }
    }

    SettingsGroupHeader("Spacing")
    SettingsRow("Avoid overlapping clips", description: "Keep clips from the same part of a set apart. Off: your scores decide.") {
      DSSwitch(isOn: model.toggleBinding(\.avoidOverlap, "Avoid overlapping clips")).accessibilityLabel("Avoid overlapping clips")
    }
    SettingsRow("Keep apart for", description: "Minimum days between overlapping clips.",
                disabledReason: model.settings.avoidOverlap ? nil : "Turn on Avoid overlapping clips first.") {
      DSXStepper(label: "Keep apart for", int: model.binding(\.avoidOverlapDays) { "Keep apart for \(SettingsFmt.days($0))" },
                 range: 1...14, format: SettingsFmt.days)
    }
  }

  private func overrideBinding(_ p: Platform) -> Binding<SortDirection?> {
    Binding(get: { model.settings.sortOverrides[p] }, set: { v in
      model.update("\(p.displayName) order set to \(v?.displayName ?? "Same as Order")") { $0.sortOverrides[p] = v }
    })
  }
}

// MARK: Rendering

struct RenderingSettings: View {
  @Bindable var model: AppModel
  @State private var deleteDays = 30

  var body: some View {
    SettingsGroupHeader("Audio", first: true)
    SettingsRow("Loudness target", description: "Integrated loudness every render is normalised to.") {
      DSXStepper(label: "Loudness target", value: model.binding(\.loudnessTarget) { String(format: "Loudness target set to %.0f LUFS", $0) },
                 range: -24 ... -8, less: "Make renders quieter", more: "Make renders louder") { String(format: "%.0f LUFS", $0) }
    }
    SettingsRow("True peak", description: "Ceiling for the loudest sample.") {
      DSXStepper(label: "True peak", value: model.binding(\.truePeak) { String(format: "True peak set to %.1f dBTP", $0) },
                 range: -3...0, step: 0.5, less: "Lower the loudest-sample ceiling", more: "Raise the loudest-sample ceiling") {
        String(format: "%.1f dBTP", $0)
      }
    }
    SettingsRow("Loudness range", description: "How much the loudness may vary across the clip.") {
      DSXStepper(label: "Loudness range", value: model.binding(\.lra) { String(format: "Loudness range set to %.0f LU", $0) },
                 range: 5...20, less: "Allow less loudness variation", more: "Allow more loudness variation") { String(format: "%.0f LU", $0) }
    }

    SettingsGroupHeader("Video")
    SettingsRow("Bitrate", description: "Video bitrate of every render.") {
      DSXStepper(label: "Bitrate", int: Binding(get: { model.settings.videoBitrateKbps / 1000 },
                                                set: { v in model.update("Bitrate set to \(v) Mbps") { $0.videoBitrateKbps = v * 1000 } }),
                 range: 4...40) { "\($0) Mbps" }
    }
    SettingsRow("Render ahead", description: "Scheduled posts are rendered this far ahead.") {
      DSXStepper(label: "Render ahead", int: model.binding(\.renderHorizonDays) { "Render ahead set to \(SettingsFmt.days($0))" },
                 range: 1...14, format: SettingsFmt.days)
    }

    SettingsGroupHeader("Posted renders")
    SettingsRow("Cleanup", description: "What happens to a render once every platform has posted it.") {
      SettingsSelect(label: "Cleanup", selection: keepBinding, options: [
        DSSelectOption(value: true, title: "Keep forever"),
        DSSelectOption(value: false, title: "Delete after a while"),
      ])
    }
    SettingsRow("Delete after", description: "Days after the last platform posted.", disabledReason: deleteAfter == nil ? "Only used when Cleanup deletes renders." : nil) {
      DSXStepper(label: "Delete after", int: Binding(get: { deleteAfter ?? deleteDays }, set: { v in setDeleteAfter(v) }),
                 range: 1...365, less: "Delete posted renders sooner", more: "Delete posted renders later", format: SettingsFmt.days)
    }
  }

  private var deleteAfter: Int? {
    if case .deleteAfter(let d) = model.settings.cleanup { return d }
    return nil
  }

  /// Turning deletion on asks first: the engine then deletes posted render files (the source footage stays).
  private var keepBinding: Binding<Bool> {
    Binding(get: { deleteAfter == nil }, set: { keep in
      if keep {
        model.update("Posted renders kept forever") { $0.cleanup = .keep }
      } else if deleteAfter == nil {
        let d = deleteDays
        model.confirm(ConfirmRequest(
          title: "Delete posted renders after \(SettingsFmt.days(d))?",
          message: "The engine deletes each render file \(SettingsFmt.days(d)) after its last platform posted it, starting on its next pass. Your source footage is never touched. Undo restores the setting, not deleted files.",
          verb: "Delete after \(SettingsFmt.days(d))", icon: "trash", destructive: true) {
            model.update("Posted renders now deleted after \(SettingsFmt.days(d))") { $0.cleanup = .deleteAfter(days: d) }
          })
      }
    })
  }

  /// Lowering the delay makes older renders eligible at once, so that asks first; raising it doesn't.
  private func setDeleteAfter(_ v: Int) {
    let apply = {
      deleteDays = v
      model.update("Delete after set to \(SettingsFmt.days(v))") { $0.cleanup = .deleteAfter(days: v) }
    }
    guard let current = deleteAfter, v < current else { apply(); return }
    model.confirm(ConfirmRequest(
      title: "Delete posted renders after \(SettingsFmt.days(v))?",
      message: "Renders posted more than \(SettingsFmt.days(v)) ago are deleted on the engine's next pass. Undo restores the setting, not deleted files.",
      verb: "Delete after \(SettingsFmt.days(v))", icon: "trash", destructive: true, action: apply))
  }
}

// MARK: Playback & autoplay

struct PlaybackSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    let off = model.playback.autoplay ? nil : "Turn on Autoplay previews first."
    SettingsRow("Autoplay previews", description: "Clips play from small preview copies made in the background. Off, lists, Score and the Calendar show covers.") {
      DSSwitch(isOn: model.playbackBinding(\.autoplay)).accessibilityLabel("Autoplay previews")
    }
    SettingsRow("Unmute on hover", description: "Hovering a clip plays it with sound (one clip at a time); moving away mutes it again. Calendar covers stay muted. Previews never unmute by themselves.",
                disabledReason: off) {
      DSSwitch(isOn: Binding(get: { model.playback.unmuteOnHover },
                             set: { v in model.setPlayback { $0.chooseUnmuteOnHover(v) } }))
        .accessibilityLabel("Unmute on hover")
    }
    SettingsRow("Small previews: play on hover only", description: "Calendar, Cards, Grid and List show covers; a clip plays only while the pointer is on it. Single view and full previews play by themselves.",
                disabledReason: off) {
      DSSwitch(isOn: Binding(get: { model.playback.gridHoverOnly },
                             set: { v in model.setPlayback { $0.chooseGridHoverOnly(v) } }))
        .accessibilityLabel("Small previews: play on hover only")
    }
    SettingsRow("Which clips play", description: "With hover-only off: all visible clips in Calendar, Cards and Grid play, at most 4 at once, or only the one you're on.",
                disabledReason: off ?? (model.playback.gridHoverOnly ? "Turn off Small previews: play on hover only first." : nil)) {
      SettingsSelect(label: "Which clips play", selection: model.playbackBinding(\.focusOnly), options: [
        DSSelectOption(value: false, title: "All visible (up to 4)"),
        DSSelectOption(value: true, title: "Only the focused clip"),
      ])
    }
    SettingsRow("Loop", description: "The trim is what will post; the whole file shows everything around it.", disabledReason: off) {
      SettingsSelect(label: "Loop", selection: model.playbackBinding(\.loop), options: [
        DSSelectOption(value: ProxyRange.trim, title: "The trim"),
        DSSelectOption(value: ProxyRange.wholeFile, title: "The whole file"),
      ])
    }
    SettingsRow("Arrow keys jump", description: "In the editor, ← and → move the playhead this far (⇧ moves one frame). The jump buttons beside Play match it.",
                stacked: true) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        SettingsSelect(label: "Arrow keys jump", selection: model.playbackBinding(\.arrowStep),
                       options: ArrowStep.allCases.map { DSSelectOption(value: $0, title: $0.title) })
        ArrowStepTryIt(step: model.playback.arrowStep)
      }
    }
    SettingsNote("Saved on this Mac. Changing Loop makes new preview copies the next time clips are on screen.")
  }
}

/// Settings → Playback "Try it" (round 19): a 30-second strip that takes ← / → with the chosen step, so Eric can feel
/// a step before going back to a clip. Click it (or Tab to it), then press the arrows; ⇧ moves one frame. A click arms
/// it through a window key monitor as well as SwiftUI focus, so the arrows work the moment it's clicked; a click
/// anywhere else lets go.
struct ArrowStepTryIt: View {
  let step: ArrowStep
  static let length = 30.0
  static let fps = 30.0
  @StateObject private var strip = TryItState()
  @State private var hovering = false
  @FocusState private var focused: Bool

  private var active: Bool { strip.armed || focused }
  private var time: Double { strip.time }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: DS.space.xs) {
        Text("Try it").font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
        Text(active ? "Press ← → (⇧ for one frame)" : "Click the strip, then press ← →")
          .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        Spacer()
        Text("\(EditorGeometry.time(time, tenths: true)) / \(EditorGeometry.time(Self.length))")
          .font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
      }
      GeometryReader { g in
        let w = g.size.width
        let x = w * time / Self.length
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous).fill(DS.color.surfaceSunken)
          // One tick per step (whole seconds when the step is under a second, so frames don't fill the strip).
          let every = max(1, step.seconds(fps: Self.fps))
          ForEach(Array(stride(from: every, to: Self.length, by: every)), id: \.self) { t in
            Rectangle().fill(DS.color.borderStrong).frame(width: 1, height: 8)
              .offset(x: w * t / Self.length, y: 0)
          }
          Rectangle().fill(DS.color.primary.opacity(0.08)).frame(width: max(0, x))
          RoundedRectangle(cornerRadius: 1).fill(DS.color.primary).frame(width: 2).offset(x: max(0, min(w - 2, x - 1)))
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
          .strokeBorder(hovering && !active ? DS.color.borderStrong : DS.color.border))
        .contentShape(Rectangle())
        // A press (or drag) puts the playhead there and arms the arrows, like clicking a scrubber.
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
          strip.time = min(Self.length, max(0, Self.length * v.location.x / max(1, w)))
          focused = true
        })
      }
      .frame(height: 32)
      .dsFocusRing(active, radius: DS.radius.sm)
      .background(TryItKeys(strip: strip, step: step))
      .background(ScriptAnchor("Arrow step try"))
    }
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
      move(press.key == .leftArrow ? -1 : 1, fine: press.modifiers.contains(.shift))
      return .handled
    }
    .onHover { hovering = $0 }
    .accessibilityElement()
    .accessibilityLabel("Try the arrow step")
    .accessibilityValue(EditorGeometry.time(time, tenths: true))
    .accessibilityAdjustableAction { d in move(d == .increment ? 1 : -1, fine: false) }
  }

  private func move(_ d: Int, fine: Bool) { strip.move(d, step: step, fine: fine) }
}

/// The try-it strip's playhead and whether its arrows are armed (a reference, so the window key monitor and the view
/// share one value).
@MainActor
final class TryItState: ObservableObject {
  /// The newest strip, for the live check (`EditorKeysScript`) to read.
  static weak var latest: TryItState?
  init() { Self.latest = self }
  @Published var time = 0.0
  @Published var armed = false
  func move(_ d: Int, step: ArrowStep, fine: Bool) {
    time = EditorSeek.target(from: time, step: step, fps: ArrowStepTryIt.fps, direction: d, fine: fine,
                             duration: ArrowStepTryIt.length)
  }
}

/// The try-it strip's arrows while it's armed: ← / → (⇧ one frame) in its window, unless a text field has the cursor.
/// `TryItState` holds the armed flag: a mouse-down on the strip arms it and puts the playhead there, one anywhere else lets go (seen by a window
/// monitor before the click is handled, so the arrows work straight after the click, focus or not).
private struct TryItKeys: NSViewRepresentable {
  let strip: TryItState
  let step: ArrowStep
  func makeNSView(context: Context) -> KeyView { KeyView() }
  func updateNSView(_ v: KeyView, context: Context) {
    v.strip = strip
    v.step = step
  }
  final class KeyView: NSView {
    weak var strip: TryItState?
    var step = ArrowStep.standard
    private var monitors: [Any] = []
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      monitors.forEach(NSEvent.removeMonitor)
      monitors = []
      strip?.armed = false
      guard window != nil else { return }
      if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
        guard let self, let strip = self.strip, strip.armed, e.window === self.window else { return e }
        // Any other key (Tab to another control, typing) lets go: the arrows are the strip's only while it's in use.
        guard !(self.window?.firstResponder is NSTextView),
              e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              e.keyCode == EditorKeys.left || e.keyCode == EditorKeys.right else { strip.armed = false; return e }
        strip.move(e.keyCode == EditorKeys.left ? -1 : 1, step: self.step, fine: e.modifierFlags.contains(.shift))
        return nil
      }) { monitors.append(m) }
      if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
        guard let self, let strip = self.strip, e.window === self.window, !self.isHiddenOrHasHiddenAncestor else { return e }
        let p = self.convert(e.locationInWindow, from: nil)
        let inside = self.bounds.contains(p)
        if inside != strip.armed { strip.armed = inside }
        // The press puts the playhead there (a drag carries on through the strip's own gesture).
        if inside { strip.time = ArrowStepTryIt.length * min(1, max(0, p.x / max(1, self.bounds.width))) }
        return e
      }) { monitors.append(m) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { monitors.forEach(NSEvent.removeMonitor) }
  }
}

// MARK: Alerts

struct AlertsSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsGroupHeader("Queue", first: true)
    SettingsRow("Low Queue alert", description: "Card and notification when fewer days than this are scheduled and the Queue is about out.") {
      DSXStepper(label: "Low Queue alert", int: model.binding(\.approvedRunwayAlertDays) { "Low Queue alert at \(SettingsFmt.days($0)) left" },
                 range: 1...14, less: "Alert when fewer days are scheduled", more: "Alert when more days are scheduled",
                 format: SettingsFmt.days)
    }
    SettingsRow("Record a new set", description: "Card and notification when scheduled days plus clips waiting drop below this.") {
      DSXStepper(label: "Record a new set", int: model.binding(\.totalRunwayAlertDays) { "New-set alert at \(SettingsFmt.days($0)) left" },
                 range: 3...60, less: "Alert when fewer days of clips are left", more: "Alert when more days of clips are left",
                 format: SettingsFmt.days)
    }

    SettingsGroupHeader("Reminders")
    SettingsRow("Slot reminders", description: "One notification per slot; silent when it's already posted.") {
      DSBadge("Always on", style: .soft(.neutral), help: "Slot reminders can't be turned off")
    }
    SettingsRow("Copyright and failed posts", description: "Red card on every screen and a red badge on the menu-bar icon.") {
      DSBadge("Always on", style: .soft(.neutral), help: "Problem alerts can't be turned off")
    }
  }
}
