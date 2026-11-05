import DJQCore
import SwiftUI

// Settings → Publishing (round 6, P5/P6). Three short groups: the Postiz connection (key + status + check), one row
// per platform (Manual | Postiz, the channel and an expandable detail with that platform's few Postiz options), and
// the Test run switch. Every change saves at once and is undoable (toast · ⌘Z); removing the key asks first.
// Refs: Meetup "Mailchimp sync" (status chip + one action, dependent controls disabled until connected), Unify
// Integrations (one row per integration, "● Connected"), Mintlify agent settings (Connected chip + Disconnect).

struct PublishingSection: View {
  @Bindable var model: AppModel
  /// Platforms whose detail is open (snapshots preset it through `SettingsUIState.publishingExpanded`).
  @State private var expanded: Set<Platform> = SettingsUIState.shared.publishingExpanded

  var body: some View {
    SettingsGroupHeader("Postiz", description: "Postiz posts for you at each slot, even with the Mac off.", first: true)
    PostizKeyRow(model: model)
    connectionRow
    SettingsRow("Test run", description: "TikTok goes to your inbox, YouTube is unlisted, Instagram, Facebook, Threads and X are saved as Postiz drafts.") {
      DSSwitch(isOn: Binding(get: { model.settings.publishing.testMode },
                             set: { on in model.setTestRun(on) }))
        .accessibilityLabel("Test run")
    }

    SettingsGroupHeaderWithAction(title: "Platforms", description: "Who posts each platform, the Postiz channel it uses and its options.") {
      DSButton("Match channels", icon: "link", variant: .ghost, size: .sm,
               disabledReason: autoMapReason, tooltip: "Pick each platform's Postiz channel by its type") {
        model.autoMapPostizChannels()
      }
    }
    ForEach(Platform.allCases.sorted()) { p in
      PublishingPlatformRow(model: model, platform: p, isExpanded: Binding(
        get: { expanded.contains(p) },
        set: { open in dsWithAnimation { if open { expanded.insert(p) } else { expanded.remove(p) } } }))
    }

    SettingsNote("Manual stays the fallback: anything Postiz can't take goes to the Calendar with the reason.")
      .onAppear { model.loadPostizKey() }
  }

  private var autoMapReason: String? {
    if model.postiz.channels == nil { return "Check the connection first to list your Postiz channels" }
    return model.postizAutoMap().isEmpty ? "Every platform already has its channel" : nil
  }

  // MARK: Connection

  private var connectionRow: some View {
    let c = model.postizConnection
    return SettingsRow("Connection", description: connectionDetail(c)) {
      HStack(spacing: DS.space.xs) {
        connectionBadge(c)
        DSButton("Check connection", icon: "arrow.clockwise", variant: .outline, size: .sm, isLoading: model.postiz.checking,
                 disabledReason: checkReason(c), tooltip: "Ask Postiz whether the key works and list your channels") {
          model.checkPostiz()
        }
      }
      .fixedSize()
    }
  }

  @ViewBuilder private func connectionBadge(_ c: PostizConnection) -> some View {
    switch c {
    case .notSetUp: DSBadge("Not set up", style: .outline, help: "No Postiz API key yet; every platform posts manually")
    case .saved: DSBadge("Key saved", style: .soft(.neutral), help: "Check the connection to make sure Postiz accepts it")
    case .connected: DSBadge("Connected", style: .soft(.success), icon: "checkmark", help: "Postiz accepts the key")
    case .keyInvalid: DSBadge("Key invalid", style: .soft(.danger), icon: "exclamationmark", help: "Postiz refused the key; save it again")
    case .rateLimited(let until):
      DSBadge("Rate limited until \(PostizFmt.time(until, model.tz))", style: .soft(.warning), icon: "hourglass",
              help: "Postiz asked DJ Queue to slow down; calls resume by themselves")
    case .unreachable(let e): DSBadge("Can't reach Postiz", style: .soft(.warning), icon: "wifi.exclamationmark", help: e)
    }
  }

  private func connectionDetail(_ c: PostizConnection) -> String {
    switch c {
    case .notSetUp: return "Add your key to post through Postiz."
    case .saved: return "Not checked yet."
    case .connected:
      let n = model.postiz.channels?.count ?? 0
      let at = (model.postiz.checkedAt ?? model.postiz.channelsFetchedAt).map { "Checked \(PostizFmt.time($0, model.tz))" }
      return [at, "\(n) channel\(n == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
    case .keyInvalid: return "Save the key again; until then Postiz posts go to the Calendar as manual posts."
    case .rateLimited: return "Calls resume by themselves."
    case .unreachable(let e): return e
    }
  }

  private func checkReason(_ c: PostizConnection) -> String? {
    if case .notSetUp = c { return "Add your Postiz API key first" }
    if case .rateLimited(let until) = c { return "Postiz asked for a pause until \(PostizFmt.time(until, model.tz))" }
    return nil
  }
}

/// "Postiz API key": a secure field with Save while none is saved; "Saved in Keychain" with Replace / Remove once
/// it is. The value is never shown or read back.
struct PostizKeyRow: View {
  @Bindable var model: AppModel
  @State private var text = ""
  @State private var replacing = SettingsUIState.shared.publishingReplacingKey
  @State private var saving = false
  @State private var error: String?

  var body: some View {
    let has = model.postiz.hasKey ?? false
    SettingsRow("Postiz API key", description: description(has)) {
      if has && !replacing {
        HStack(spacing: DS.space.xxs) {
          DSButton("Replace", variant: .ghost, size: .sm, tooltip: "Paste a new key instead of the saved one") { replacing = true }
          DSButton("Remove", variant: .ghost, size: .sm, tooltip: "Delete the key from the Keychain (asks first)") { model.removePostizKey() }
        }
        .fixedSize()
      } else {
        HStack(spacing: DS.space.xxs) {
          DSTextField(placeholder: "Paste the API key", text: $text, size: .sm, isSecure: true, onSubmit: save)
            .frame(width: 190)
            .accessibilityLabel("Postiz API key")
          if replacing {
            DSButton("Cancel", variant: .ghost, size: .sm, tooltip: "Keep the saved key") { replacing = false; text = ""; error = nil }
          }
          DSButton("Save", variant: .primary, size: .sm, isLoading: saving,
                   disabledReason: text.trimmingCharacters(in: .whitespaces).isEmpty ? "Paste the key first" : nil,
                   tooltip: "Save the key in the Keychain and check it") { save() }
        }
        .fixedSize()
      }
    }
  }

  private func description(_ has: Bool) -> String {
    if let error { return error }
    if has && !replacing { return "Saved in Keychain · never shown here" }
    return "Postiz → Settings → Public API · kept in the Keychain"
  }

  private func save() {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !saving else { return }
    saving = true
    error = nil
    model.savePostizKey(text) { err in
      saving = false
      error = err
      if err == nil { text = ""; replacing = false }
    }
  }
}

/// One platform: glyph · name · who posts it (and the channel) · Manual | Postiz · ⌄ for its detail.
struct PublishingPlatformRow: View {
  @Bindable var model: AppModel
  let platform: Platform
  @Binding var isExpanded: Bool

  var body: some View {
    let p = platform
    let kind = model.settings.publishing.publisher(for: p)
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: DS.space.md) {
        DSPlatformIcon(platform: p, size: 26).padding(.top, 1)
        VStack(alignment: .leading, spacing: 2) {
          Text(p.displayName).font(DS.type.body).foregroundStyle(DS.color.text)
          Text(summary(kind)).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        Spacer(minLength: DS.space.sm)
        HStack(spacing: DS.space.xs) {
          stateBadge(kind)
          DSSegmented(selection: Binding(get: { kind }, set: { model.setPublisher(p, $0) }), segments: [
            DSSegment(value: PublisherKind.manual, title: "Manual", tooltip: "You post \(p.displayName) yourself from the Calendar"),
            DSSegment(value: PublisherKind.postiz, title: "Postiz", tooltip: "Postiz posts \(p.displayName) at its slot",
                      disabledReason: kind == .postiz ? nil : model.postizUnavailableReason(p)),
          ], size: .sm)
          .accessibilityLabel("\(p.displayName) publisher")
          DSIconButton(isExpanded ? "chevron.up" : "chevron.down",
                       tooltip: isExpanded ? "Hide \(p.displayName)'s Postiz options" : "Show \(p.displayName)'s channel and Postiz options",
                       size: .sm) { isExpanded.toggle() }
        }
        .fixedSize()
        .frame(minHeight: DS.size.controlSm)
      }
      .padding(.vertical, 14)
      if isExpanded {
        PublishingPlatformDetail(model: model, platform: p)
          .padding(.leading, 26 + DS.space.md)
          .padding(.bottom, DS.space.md)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) { DSSeparator() }
    .accessibilityElement(children: .contain)
    .settingsAnchor(SettingsAnchor.row(platform.displayName))
  }

  private func summary(_ kind: PublisherKind) -> String {
    let ch = model.postiz.channel(model.settings.publishing.channels[platform])
    if kind == .manual { return "Manual · you post it from the Calendar" }
    switch model.postizRoute(platform) {
    case .postiz: return "Postiz · " + (ch.map { "\($0.name) · \($0.identifier)" } ?? "channel picked")
    case .fallback(let r): return Self.short(r)
    case .manual: return "Manual"
    }
  }

  /// One line under the platform name; the badge's tooltip has the full sentence.
  static func short(_ r: PostizFallbackReason) -> String {
    switch r {
    case .noKey: "No API key yet · you post it by hand"
    case .keyInvalid: "Key refused · you post it by hand"
    case .noChannel: "No channel picked · you post it by hand"
    case .channelDisabled: "Reconnect it in Postiz · you post it by hand"
    case .channelMissing: "Channel gone from Postiz · pick it again"
    case .createRejected: "Postiz refused a post · you post it by hand"
    case .vanished: "Deleted in Postiz · you post it by hand"
    }
  }

  @ViewBuilder private func stateBadge(_ kind: PublisherKind) -> some View {
    let ch = model.postiz.channel(model.settings.publishing.channels[platform])
    if ch?.disabled == true {
      DSBadge("Channel disabled", style: .soft(.danger), icon: "exclamationmark",
              help: "\(ch?.name ?? "This channel") is disabled or needs reconnecting in Postiz")
    } else if kind == .postiz, let r = model.postizRoute(platform).fallbackReason {
      DSBadge("Post by hand", style: .soft(.warning), help: r.message)
    }
  }
}

/// The expanded detail: the channel and the platform's Postiz options with their defaults.
struct PublishingPlatformDetail: View {
  @Bindable var model: AppModel
  let platform: Platform

  var body: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      line("Channel") { channelPicker }
      switch platform {
      case .tiktok:
        line("Posting") {
          SettingsSelect(label: "TikTok posting",
                         selection: guarded(\.tiktok.method, .tiktok, morePublic: { $0 == .directPost }) { "TikTok: \($0.displayName)" },
                         options: TikTokPostingMethod.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
        }
        line("Allow") {
          DSChipGroup(options: [DSChipOption(value: "comment", title: "Comments", tooltip: "Let people comment"),
                                DSChipOption(value: "duet", title: "Duet", tooltip: "Let people duet this video"),
                                DSChipOption(value: "stitch", title: "Stitch", tooltip: "Let people stitch this video")],
                      selection: tiktokAllow, size: .sm)
        }
        testNote("Test run sends TikTok to your inbox whatever Posting says.")
      case .youtube:
        line("Visibility") {
          SettingsSelect(label: "YouTube visibility",
                         selection: guarded(\.youtube.visibility, .youtube, morePublic: { $0 == .public }) { "YouTube visibility: \($0.displayName)" },
                         options: YouTubeVisibility.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
        }
        line("Made for kids") {
          SettingsSelect(label: "Made for kids", selection: bind(\.youtube.madeForKids) { "Made for kids: \($0 ? "Yes" : "No")" },
                         options: [DSSelectOption(value: false, title: "No"), DSSelectOption(value: true, title: "Yes")])
        }
        testNote("Test run posts YouTube as Unlisted.")
      case .instagram:
        line("Post as") { DSBadge("Reel", style: .outline, help: "A single video always posts as a Reel") }
        line("Trial reel") {
          DSSwitch(isOn: bind(\.instagram.trialReel) { "Trial reel turned \($0 ? "on" : "off")" }, small: true)
            .accessibilityLabel("Trial reel")
            .dsTooltip("Show the Reel to non-followers first")
        }
      case .x:
        line("Who can reply") {
          SettingsSelect(label: "Who can reply on X", selection: bind(\.x.whoCanReply) { "X replies: \($0.displayName)" },
                         options: XWhoCanReply.allCases.map { DSSelectOption(value: $0, title: $0.displayName) })
        }
      case .facebook, .threads:
        Text("No options: Postiz posts the video with its caption.")
          .font(DS.type.caption).foregroundStyle(DS.color.textTertiary).padding(.vertical, DS.space.xxs)
      }
    }
  }

  @ViewBuilder private var channelPicker: some View {
    let mine = model.postizChannels(for: platform)
    if model.postiz.channels == nil {
      Text("Check the connection to list your channels").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    } else if mine.isEmpty {
      Text("No \(platform.displayName) channel in Postiz — connect one there").font(DS.type.caption).foregroundStyle(DS.color.warning)
    } else {
      SettingsSelect(label: "\(platform.displayName) Postiz channel",
                     selection: Binding(get: { model.settings.publishing.channels[platform] },
                                        set: { model.setPostizChannel(platform, $0) }),
                     options: [DSSelectOption(value: String?.none, title: "None")]
                       + mine.map { c in DSSelectOption(value: String?.some(c.id), title: c.disabled ? "\(c.name) (disabled)" : c.name,
                                                        detail: c.identifier) })
    }
  }

  private func line<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
    HStack(spacing: DS.space.sm) {
      Text(label).font(DS.type.callout).foregroundStyle(DS.color.textSecondary).frame(width: 110, alignment: .leading)
      control()
      Spacer(minLength: 0)
    }
    .frame(minHeight: DS.size.controlSm)
  }

  @ViewBuilder private func testNote(_ text: String) -> some View {
    if model.settings.publishing.testMode {
      SettingsNote(text, icon: "testtube.2").padding(.top, -DS.space.xs)
    }
  }

  private func bind<T: Equatable>(_ kp: WritableKeyPath<DJQCore.PublishingSettings, T>, _ label: @escaping (T) -> String) -> Binding<T> {
    Binding(get: { model.settings.publishing[keyPath: kp] },
            set: { v in model.update(label(v)) { $0.publishing[keyPath: kp] = v } })
  }

  /// Like `bind`, but a change that makes posts more public asks first (`AppModel.setPublishingOption`).
  private func guarded<T: Equatable>(_ kp: WritableKeyPath<DJQCore.PublishingSettings, T>, _ p: Platform,
                                     morePublic: @escaping (T) -> Bool, _ label: @escaping (T) -> String) -> Binding<T> {
    Binding(get: { model.settings.publishing[keyPath: kp] }, set: { v in
      model.setPublishingOption(label(v), platform: p, morePublic: morePublic(v)) { $0.publishing[keyPath: kp] = v }
    })
  }

  private var tiktokAllow: Binding<Set<String>> {
    Binding(get: {
      let t = model.settings.publishing.tiktok
      return Set([t.comment ? "comment" : nil, t.duet ? "duet" : nil, t.stitch ? "stitch" : nil].compactMap { $0 })
    }, set: { s in
      model.update("TikTok allows \(s.isEmpty ? "nothing" : ["comment": "comments", "duet": "duets", "stitch": "stitches"].filter { s.contains($0.key) }.map(\.value).sorted().joined(separator: ", "))") { st in
        st.publishing.tiktok.comment = s.contains("comment")
        st.publishing.tiktok.duet = s.contains("duet")
        st.publishing.tiktok.stitch = s.contains("stitch")
      }
    })
  }
}

/// A settings group header with a trailing action (Match channels).
struct SettingsGroupHeaderWithAction<Action: View>: View {
  let title: String
  var description: String? = nil
  @ViewBuilder var action: Action

  var body: some View {
    HStack(alignment: .bottom) {
      SettingsGroupHeader(title, description: description)
      Spacer(minLength: DS.space.sm)
      action.padding(.bottom, DS.space.xxs)
    }
  }
}

enum PostizFmt {
  /// "8:40 PM" in the app's zone.
  static func time(_ d: Date, _ tz: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.timeZone = tz
    f.dateFormat = "h:mm a"
    return f.string(from: d)
  }
}
