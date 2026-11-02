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
      DSXStepper(label: "Posts per day", int: model.binding(\.postsPerDay), range: 1...5) { "\($0) per day" }
    }
    SettingsRow("Time zone", description: "Slot times, days and reminders use this zone.") {
      SettingsSelect(label: "Time zone", selection: model.binding(\.timeZone), options: timeZones)
    }
    SettingsRow("Week starts on", description: "First day of the Week screen and of each approval.") {
      SettingsSelect(label: "Week starts on", selection: model.binding(\.weekStartsOn),
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
    SettingsRow("Publisher", description: "You post from the Mac browser; the app prepares the file and caption.") {
      DSBadge("Manual", style: .outline)
    }
    SettingsRow("Postiz API key", description: "Stored in the Keychain.", disabledReason: "Not available yet — arrives with automatic posting.") {
      DSTextField(placeholder: "Not available yet", text: .constant(""), size: .sm).frame(width: 180)
    }
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
      model.update { s in
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
        Text("Title").frame(width: 76, alignment: .trailing)
      }
      .font(DS.type.captionMedium)
      .foregroundStyle(DS.color.textSecondary)
      .frame(height: 32)
      .overlay(alignment: .bottom) { DSSeparator() }
      ForEach(Platform.allCases.sorted()) { p in
        HStack(spacing: DS.space.xs) {
          DSPlatformIcon(platform: p, size: 22, showsLabel: true).frame(maxWidth: .infinity, alignment: .leading)
          field("\(p.displayName) maximum length in seconds", limit(p).map { Int($0.maxDuration) }) { v in setLimit(p) { $0.maxDuration = Double(v) } }
          field("\(p.displayName) maximum size in MB", limit(p).map { Int($0.maxBytes / 1_000_000) }) { v in setLimit(p) { $0.maxBytes = Int64(v) * 1_000_000 } }
          field("\(p.displayName) caption characters", limit(p)?.captionLimit) { v in setLimit(p) { $0.captionLimit = v } }
          if p == .youtube {
            field("YouTube title characters", limit(p)?.titleLimit) { v in setLimit(p) { $0.titleLimit = v } }
          } else {
            Text("—").font(DS.type.callout).foregroundStyle(DS.color.textTertiary).frame(width: 76, alignment: .trailing)
              .dsTooltip("Only YouTube has a title")
          }
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) { DSSeparator() }
      }
    }
  }

  private func field(_ label: String, _ value: Int?, _ set: @escaping (Int) -> Void) -> some View {
    SettingsNumberField(label: label, value: value ?? 0, commit: set).frame(width: 76)
  }

  private func limit(_ p: Platform) -> PlatformLimits? { model.settings.limits[p] ?? PlatformLimits.defaults[p] }

  private func setLimit(_ p: Platform, _ change: @escaping (inout PlatformLimits) -> Void) {
    model.update { s in
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
      SettingsRow(p.displayName, platform: p) {
        SettingsSelect(label: "\(p.displayName) slot time", selection: slotBinding(p),
                       options: SettingsFmt.timeOptions(current: model.settings.slot(for: p)))
      }
    }
    HStack {
      Spacer()
      DSButton("Reset slot times", icon: "arrow.counterclockwise", variant: .ghost, size: .sm,
               disabledReason: slotsAreDefault ? "Slot times are already the built-in times" : nil) {
        model.update { s in for p in Platform.allCases { s.slotMinutes[p] = p.defaultSlotMinutes } }
      }
    }
    .padding(.top, DS.space.xs)

    SettingsGroupHeader("Posting")
    SettingsRow("Second post offset", description: "Extra posts on the same day use the same slots, shifted by this much.",
                disabledReason: model.settings.postsPerDay < 2 ? "Only used with 2 or more posts per day (General)." : nil) {
      DSXStepper(label: "Second post offset", int: Binding(get: { model.settings.secondPostOffsetMinutes / 60 },
                                                           set: { v in model.update { $0.secondPostOffsetMinutes = v * 60 } }),
                 range: 1...6) { "+\($0) h" }
    }
    SettingsRow("Post early", description: "Allow posting any time on the day, before the slot.") {
      DSSwitch(isOn: model.binding(\.allowEarlyPosting)).accessibilityLabel("Post early")
    }
    SettingsRow("Late grace", description: "A post is still due this long after its slot; after that the plan shifts.") {
      DSXStepper(label: "Late grace", value: model.binding(\.lateGraceHours), range: 1...12, format: SettingsFmt.hours)
    }
    SettingsRow("Retry stagger", description: "Re-queued failures post this long after the day's slot.") {
      DSXStepper(label: "Retry stagger", value: model.binding(\.retryStaggerHours), range: 1...8, format: SettingsFmt.hours)
    }
    SettingsRow("Repost cooldown", description: "Days before the same clip can post again on a platform.") {
      DSXStepper(label: "Repost cooldown", int: model.binding(\.repostCooldownDays), range: 1...90, format: SettingsFmt.days)
    }
  }

  private var slotsAreDefault: Bool { Platform.allCases.allSatisfy { model.settings.slot(for: $0) == $0.defaultSlotMinutes } }

  private func slotBinding(_ p: Platform) -> Binding<Int> {
    Binding(get: { model.settings.slot(for: p) }, set: { v in model.update { $0.slotMinutes[p] = v } })
  }
}

// MARK: Queue

struct QueueSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsRow("Order", description: "Orders the unplanned backlog by score. Planned days don't move.") {
      SettingsSelect(label: "Order", selection: model.binding(\.sort),
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
      DSSwitch(isOn: model.binding(\.avoidOverlap)).accessibilityLabel("Avoid overlapping clips")
    }
    SettingsRow("Keep apart for", description: "Minimum days between overlapping clips.",
                disabledReason: model.settings.avoidOverlap ? nil : "Turn on Avoid overlapping clips first.") {
      DSXStepper(label: "Keep apart for", int: model.binding(\.avoidOverlapDays), range: 1...14, format: SettingsFmt.days)
    }
  }

  private func overrideBinding(_ p: Platform) -> Binding<SortDirection?> {
    Binding(get: { model.settings.sortOverrides[p] }, set: { v in model.update { $0.sortOverrides[p] = v } })
  }
}

// MARK: Rendering

struct RenderingSettings: View {
  @Bindable var model: AppModel
  @State private var deleteDays = 30

  var body: some View {
    SettingsGroupHeader("Audio", first: true)
    SettingsRow("Loudness target", description: "Integrated loudness every render is normalised to.") {
      DSXStepper(label: "Loudness target", value: model.binding(\.loudnessTarget), range: -24 ... -8) { String(format: "%.0f LUFS", $0) }
    }
    SettingsRow("True peak", description: "Ceiling for the loudest sample.") {
      DSXStepper(label: "True peak", value: model.binding(\.truePeak), range: -3...0, step: 0.5) { String(format: "%.1f dBTP", $0) }
    }
    SettingsRow("Loudness range", description: "How much the loudness may vary across the clip.") {
      DSXStepper(label: "Loudness range", value: model.binding(\.lra), range: 5...20) { String(format: "%.0f LU", $0) }
    }

    SettingsGroupHeader("Video")
    SettingsRow("Bitrate", description: "Video bitrate of every render.") {
      DSXStepper(label: "Bitrate", int: Binding(get: { model.settings.videoBitrateKbps / 1000 },
                                                set: { v in model.update { $0.videoBitrateKbps = v * 1000 } }),
                 range: 4...40) { "\($0) Mbps" }
    }
    SettingsRow("Render ahead", description: "Approved posts are rendered this far ahead.") {
      DSXStepper(label: "Render ahead", int: model.binding(\.renderHorizonDays), range: 1...14, format: SettingsFmt.days)
    }

    SettingsGroupHeader("Posted renders")
    SettingsRow("Cleanup", description: "What happens to a render once every platform has posted it.") {
      SettingsSelect(label: "Cleanup", selection: keepBinding, options: [
        DSSelectOption(value: true, title: "Keep forever"),
        DSSelectOption(value: false, title: "Delete after a while"),
      ])
    }
    SettingsRow("Delete after", description: "Days after the last platform posted.", disabledReason: deleteAfter == nil ? "Only used when Cleanup deletes renders." : nil) {
      DSXStepper(label: "Delete after", int: Binding(get: { deleteAfter ?? deleteDays }, set: { v in
        deleteDays = v
        model.update { $0.cleanup = .deleteAfter(days: v) }
      }), range: 1...365, format: SettingsFmt.days)
    }
  }

  private var deleteAfter: Int? {
    if case .deleteAfter(let d) = model.settings.cleanup { return d }
    return nil
  }

  private var keepBinding: Binding<Bool> {
    Binding(get: { deleteAfter == nil }, set: { keep in model.update { $0.cleanup = keep ? .keep : .deleteAfter(days: deleteDays) } })
  }
}

// MARK: Playback & autoplay

struct PlaybackSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    let off = model.playback.autoplay ? nil : "Turn on Autoplay previews first."
    SettingsRow("Autoplay previews", description: "Visible clips play muted from small preview copies made in the background.") {
      DSSwitch(isOn: model.playbackBinding(\.autoplay)).accessibilityLabel("Autoplay previews")
    }
    SettingsRow("Unmute on hover", description: "Hovering a clip plays it with sound (one clip at a time); moving away mutes it again. Previews never unmute by themselves.",
                disabledReason: off) {
      DSSwitch(isOn: Binding(get: { model.playback.unmuteOnHover },
                             set: { v in model.setPlayback { $0.chooseUnmuteOnHover(v) } }))
        .accessibilityLabel("Unmute on hover")
    }
    SettingsRow("Grids: play on hover only", description: "Grid views show covers; a tile plays only while the pointer is on it.",
                disabledReason: off) {
      DSSwitch(isOn: Binding(get: { model.playback.gridHoverOnly },
                             set: { v in model.setPlayback { $0.chooseGridHoverOnly(v) } }))
        .accessibilityLabel("Grids: play on hover only")
    }
    SettingsRow("Which clips play", description: "Cards, List and Single views: all visible clips play, at most 4 at once.",
                disabledReason: off) {
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
    SettingsNote("Saved on this Mac. Changing Loop makes new preview copies the next time clips are on screen.")
  }
}

// MARK: Alerts

struct AlertsSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    SettingsGroupHeader("Runway", first: true)
    SettingsRow("Approve next week", description: "Card and notification when approved runway drops below this.") {
      DSXStepper(label: "Approve next week", int: model.binding(\.approvedRunwayAlertDays), range: 1...14, format: SettingsFmt.days)
    }
    SettingsRow("Record a new set", description: "Card and notification when total runway drops below this.") {
      DSXStepper(label: "Record a new set", int: model.binding(\.totalRunwayAlertDays), range: 3...60, format: SettingsFmt.days)
    }

    SettingsGroupHeader("Reminders")
    SettingsRow("Approval reminder", description: "Notification if next week isn't approved by then.") {
      HStack(spacing: DS.space.xxs) {
        SettingsSelect(label: "Approval reminder day", selection: model.binding(\.approvalReminderWeekday),
                       options: (1...7).map { DSSelectOption(value: $0, title: SettingsFmt.weekday($0)) })
        SettingsSelect(label: "Approval reminder time", selection: model.binding(\.approvalReminderMinutes),
                       options: SettingsFmt.timeOptions(current: model.settings.approvalReminderMinutes))
      }
      .fixedSize()
    }
    SettingsRow("Slot reminders", description: "One notification per slot; silent when it's already posted.") {
      DSBadge("Always on", style: .soft(.neutral))
    }
    SettingsRow("Copyright and failed posts", description: "Red card on every screen and a red badge on the menu-bar icon.") {
      DSBadge("Always on", style: .soft(.neutral))
    }
  }
}
