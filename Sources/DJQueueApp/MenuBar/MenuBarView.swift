import AppKit
import DJQCore
import SwiftUI

/// MB.ICON (DESIGN-v2 §6.10): template glyph + days scheduled ("5d"); a red dot (top right) when posts need
/// attention; a smaller update dot (bottom right: blue = an update is ready, amber = one is blocked, round 4 S5);
/// grey when the engine is stopped; pause glyph while posting is paused. Drawn at display time so the colours
/// follow the menu bar's appearance (template unless a coloured dot has to keep its colour).
enum MenuBarIcon {
  /// `appearance` forces the ink (the snapshot icon sheet); nil = the appearance the image is drawn in (the status
  /// button's), so a coloured-dot icon reads white on a dark menu bar and black on a light one.
  static func image(days: Int, errors: Int, engineOn: Bool, paused: Bool, update: AutoUpdateUI.Dot = .none,
                    appearance: NSAppearance? = nil) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    let text = "\(days)d" as NSString
    let textSize = text.size(withAttributes: [.font: font])
    let symbolName = paused ? "pause.circle" : "play.square.stack"
    let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DJ Queue")?
      .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    let symW = symbol?.size.width ?? 16
    let dot: CGFloat = 6
    let updateColor: NSColor? = switch update {
    case .none: nil
    case .ready: .systemBlue
    case .blocked: .systemOrange
    }
    let size = NSSize(width: ceil(symW + 4 + textSize.width + (errors > 0 || updateColor != nil ? dot + 1 : 0)), height: 18)
    let template = errors == 0 && updateColor == nil
    let img = NSImage(size: size, flipped: false) { _ in
      let alpha: CGFloat = engineOn ? 1 : 0.4
      // Template: AppKit tints it. Otherwise pick white or black from the drawing appearance, resolved here at draw
      // time (a dynamic labelColor resolved elsewhere can come out black on a dark bar).
      let ap = appearance ?? NSAppearance.currentDrawing()
      let dark = ap.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
      let ink = template || !dark ? NSColor.black.withAlphaComponent(alpha * (template ? 1 : 0.85)) : NSColor.white.withAlphaComponent(alpha)
      if let symbol {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
          symbol.draw(in: r)
          ink.set()
          r.fill(using: .sourceAtop)
          return true
        }
        tinted.draw(in: NSRect(x: 0, y: (18 - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
      }
      text.draw(at: NSPoint(x: symW + 4, y: (18 - textSize.height) / 2), withAttributes: [.font: font, .foregroundColor: ink])
      if errors > 0 {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width - dot, y: 18 - dot - 2, width: dot, height: dot)).fill()
      }
      if let updateColor {
        let d: CGFloat = 5
        updateColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width - dot + (dot - d) / 2, y: 2, width: d, height: d)).fill()
      }
      return true
    }
    img.isTemplate = template
    var desc = "DJ Queue: \(days) days scheduled"
    if errors > 0 { desc += ", \(errors) need attention" }
    if paused { desc += ", posting paused" }
    if !engineOn { desc += ", engine stopped" }
    switch update {
    case .none: break
    case .ready(let v): desc += ", update \(v) ready"
    case .blocked(let v): desc += ", update \(v) blocked"
    }
    img.accessibilityDescription = desc
    return img
  }
}

struct MenuBarLabel: View {
  let host: AppHost

  /// "5 days scheduled · Something needs attention" (what the "5d" and the dot mean).
  @MainActor static func help(_ m: AppModel) -> String {
    let d = m.runway.approvedDays
    var parts = ["\(d) day\(d == 1 ? "" : "s") scheduled"]
    if m.settings.paused { parts.append("Posting is paused") }
    if !m.engineRunning { parts.append("The engine is stopped") }
    if !m.problems.isEmpty { parts.append("Something needs attention (\(m.problems.count))") }
    if let u = AutoUpdateUI.shared.statusText { parts.append(u) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    if let m = host.model {
      Image(nsImage: MenuBarIcon.image(days: m.runway.approvedDays, errors: m.problems.count, engineOn: m.engineRunning, paused: m.settings.paused,
                                       update: AutoUpdateUI.shared.dot))
        // The status item lives in the system menu bar, outside our windows, so DSTooltip can't reach it: the one
        // place a native help tag is right.
        .help(Self.help(m))  // native-help-ok
        // Auto-update (S5) starts with the status item: every launch mode but snapshots shows it.
        .task { AutoUpdateUI.shared.start(host: host) }
    } else {
      Image(systemName: "exclamationmark.triangle")
    }
  }
}

struct MenuBarRoot: View {
  let host: AppHost
  var body: some View {
    if let m = host.model {
      MenuBarView(model: m)
    } else {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        Label("DJ Queue can't start", systemImage: DSTone.danger.symbol)
          .font(DS.type.calloutSemibold).foregroundStyle(DS.color.danger)
        Text(host.startupError ?? "").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        DSButton("Quit", variant: .outline, size: .sm) { NSApp.terminate(nil) }
      }
      .padding(DS.space.md)
      .frame(width: 320, alignment: .leading)
      .background(DS.color.surfaceRaised)
    }
  }
}

/// What the menu-bar window shows, read from the model in one place (snapshots build variants of it).
struct MenuBarState {
  /// The post the header is about: the first one due now, else the next upcoming one.
  var next: PlatformPost?
  /// Other posts due now (≤ 3 shown).
  var due: [PlatformPost]
  var problems: [PlatformPost]
  /// Today's posts Postiz handles (≤ 4 shown).
  var postiz: [PlatformPost] = []
  var engineRunning: Bool
  var paused: Bool
  var lastTick: Date?
  /// Auto-update row (round 4 S5): ready / installing / blocked; nil = nothing to say.
  var update: UpdateRow? = nil

  enum UpdateRow: Equatable {
    case ready(String)
    case working(String)
    case blocked(version: String, reason: String)
  }

  @MainActor init(model m: AppModel) {
    let dueNow = m.dueNow.filter { $0.resolution == nil }.sorted { $0.scheduledAt < $1.scheduledAt }
    next = dueNow.first ?? m.nextPost
    due = Array(dueNow.dropFirst())
    problems = m.problems
    postiz = m.postizToday
    engineRunning = m.engineRunning
    paused = m.settings.paused
    lastTick = m.lastHeartbeat?.at
    let u = AutoUpdateUI.shared
    if u.isWorking {
      update = .working(u.workingLabel)
    } else if let r = u.state.ready {
      update = .ready(r.version)
    } else if let b = u.problem {
      update = .blocked(version: b.version, reason: b.afterInstall ? "\(b.reason) It's still installed (failed its checks)." : "\(b.reason) Nothing was installed.")
    }
  }
}

/// MB (DESIGN-v2 §6.10, `R2.MENUBAR` Crouton popover + Lyssna countdown): "Next post" + countdown (display) + the
/// clip row; [Copy caption] [Mark posted] (primary only when due); ≤ 3 due rows; "2 need attention › Review";
/// footer: Open DJ Queue · Pause posting.
struct MenuBarView: View {
  @Bindable var model: AppModel

  var body: some View {
    MenuBarContent(model: model, state: MenuBarState(model: model))
      .onAppear {
        model.popoverVisible = true
        model.refresh()
        AutoUpdateUI.shared.start(host: AppHost.shared)
        AutoUpdateUI.shared.refresh()
      }
      .onDisappear { model.popoverVisible = false }
  }
}

struct MenuBarContent: View {
  @Bindable var model: AppModel
  let state: MenuBarState
  /// Post whose inline "paste URL" field is open (the main window may be closed, so marking posted stays here).
  @State private var urlFor: String?
  @State private var url = ""
  @State private var urlError: String?
  @State private var confirmPause = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        if let n = state.next { header(n) } else { nothingNext }
        if !state.due.isEmpty { dueList }
        if !state.postiz.isEmpty { postizList }
      }
      .padding(DS.space.md)
      if !state.problems.isEmpty || !state.engineRunning || state.update != nil {
        VStack(spacing: DS.space.xs) {
          if !state.problems.isEmpty { problemsRow }
          if !state.engineRunning { engineRow }
          if let u = state.update { updateRow(u) }
        }
        .padding(.horizontal, DS.space.sm)
        .padding(.bottom, DS.space.sm)
      }
      DSSeparator()
      footer
    }
    .frame(width: 320)
    .background(DS.color.surfaceRaised)
  }

  // MARK: Header

  private func header(_ p: PlatformPost) -> some View {
    let due = model.isActionableNow(p)
    let v = model.video(p.videoId)
    let status = model.postStatus(p)
    return VStack(alignment: .leading, spacing: DS.space.sm) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.postizState(p) == .inbox ? "Finish in the TikTok app" : due ? "Post now" : "Next post")
          .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        Text(countdownText(p, status: status, due: due))
          .font(DS.type.display.monospacedDigit())
          .foregroundStyle(status.problemTone == .warning && model.postizState(p) != .inbox ? DS.color.warning : DS.color.text)
          .contentTransition(.numericText())
      }
      HStack(spacing: DS.space.sm) {
        DSXThumb(model: model, video: v, width: 27)
        VStack(alignment: .leading, spacing: 3) {
          Text(v.map(model.displayName) ?? "Missing clip").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).lineLimit(2)
          HStack(spacing: 5) {
            Image(systemName: p.platform.dsSymbol).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.color.textSecondary)
            Text(whenText(p)).font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
          }
        }
        Spacer(minLength: 0)
      }
      HStack(spacing: DS.space.xs) {
        DSButton("Copy caption", icon: "text.quote", variant: .outline, size: .sm,
                 tooltip: "Copy the \(p.platform.displayName) caption") { model.copyCaptionNamed(p) }
        if p.platform == .youtube {
          DSIconButton("textformat", tooltip: "Copy title for YouTube", variant: .ghost, size: .sm) { model.copyTitleNamed(p) }
        }
        Spacer(minLength: 0)
        DSButton("Mark posted", icon: "checkmark", variant: due ? .primary : .ghost, size: .sm,
                 tooltip: due ? "Paste the post URL" : "Not due yet — you can still mark it posted early") { toggleURL(p) }
      }
      if urlFor == p.id { urlField(p) }
    }
  }

  private var nothingNext: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Next post").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      Text("Nothing scheduled").font(DS.type.headline).foregroundStyle(DS.color.text)
      Text("Send clips to the Queue.").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
    }
  }

  private func countdownText(_ p: PlatformPost, status: DSXPostStatus, due: Bool) -> String {
    if model.postizState(p) == .inbox { return "In TikTok inbox" }
    if case .late(let t) = status { return "Late \(t)" }
    if due { return "Due now" }
    return AppModel.countdown(to: p.scheduledAt, now: model.now)
  }

  /// "TikTok · 7:00 PM" (+ weekday when not today).
  private func whenText(_ p: PlatformPost) -> String {
    let day = model.dm.key(p.scheduledAt) == model.todayKey ? "" : "\(Fmt.day(p.scheduledAt, tz: model.tz, style: "EEE")) "
    return "\(p.platform.displayName) · \(day)\(AppModel.clockText(p.scheduledAt, tz: model.tz))"
  }

  // MARK: Due list

  private var dueList: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Also due").font(DS.type.micro).foregroundStyle(DS.color.textTertiary).padding(.bottom, 2)
      ForEach(state.due.prefix(3)) { p in
        VStack(spacing: 4) {
          HStack(spacing: DS.space.xs) {
            DSPlatformIcon(platform: p.platform, state: .due, size: 22)
            VStack(alignment: .leading, spacing: 0) {
              Text(model.video(p.videoId).map(model.displayName) ?? "").font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1)
              Text("\(p.platform.dsxCompactName) · \(AppModel.clockText(p.scheduledAt, tz: model.tz))")
                .font(DS.type.caption.monospacedDigit())
                .foregroundStyle(p.state == .overdue ? DS.color.warning : DS.color.textSecondary)
            }
            Spacer(minLength: 0)
            DSIconButton("text.quote", tooltip: "Copy this post's caption", size: .sm) { model.copyCaptionNamed(p) }
            DSIconButton("checkmark.circle", tooltip: "Mark posted (paste its URL)", size: .sm, isOn: urlFor == p.id) { toggleURL(p) }
          }
          .frame(height: 36)
          if urlFor == p.id { urlField(p) }
        }
      }
      if state.due.count > 3 {
        Text("+ \(state.due.count - 3) more in Calendar").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      }
    }
  }

  // MARK: Postiz today

  /// "Postiz today": one quiet row per post Postiz handles — glyph · platform + time · state chip · its one action
  /// (open the live post, release a test-run draft).
  private var postizList: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Postiz today").font(DS.type.micro).foregroundStyle(DS.color.textTertiary).padding(.bottom, 2)
      ForEach(state.postiz.prefix(4)) { p in
        let s = model.postizState(p) ?? .queued
        HStack(spacing: DS.space.xs) {
          DSPlatformIcon(platform: p.platform, size: 22)
          VStack(alignment: .leading, spacing: 0) {
            Text(p.platform.displayName).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1)
            Text(AppModel.clockText(p.scheduledAt, tz: model.tz)).font(DS.type.caption.monospacedDigit())
              .foregroundStyle(DS.color.textSecondary)
          }
          .dsTooltip(model.video(p.videoId).map(model.displayName))
          Spacer(minLength: 0)
          if model.isTestRun(p) {
            Image(systemName: "testtube.2").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.color.textSecondary)
              .dsTooltip(TestRunBadge.help)
          }
          PostizBadge(model: model, post: p, state: s, size: .sm)
          switch s {
          case .posted(let u?):
            if let url = URL(string: u) {
              DSIconButton("arrow.up.right.square", tooltip: "Open the live post in your browser", size: .sm) { NSWorkspace.shared.open(url) }
            }
          case .draft:
            DSIconButton("paperplane", tooltip: "Release this draft so Postiz posts it", size: .sm) { model.releaseDraft(p) }
          default:
            EmptyView()
          }
        }
        .frame(height: 40)
      }
      if state.postiz.count > 4 {
        Text("+ \(state.postiz.count - 4) more in Calendar").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      }
    }
  }

  // MARK: Inline mark posted

  private func toggleURL(_ p: PlatformPost) {
    dsWithAnimation(DS.motion.hover) {
      urlFor = urlFor == p.id ? nil : p.id
      url = ""
      urlError = nil
    }
  }

  private func urlField(_ p: PlatformPost) -> some View {
    HStack(alignment: .top, spacing: DS.space.xs) {
      DSTextField(placeholder: "Paste the \(p.platform.displayName) URL", text: $url, error: urlError, size: .sm) { save(p) }
        .onChange(of: url) { urlError = nil }
      DSButton("Save", variant: .outline, size: .sm, disabledReason: url.isEmpty ? "Paste the post URL first" : nil,
               tooltip: "Mark this post as posted (undoable)", shortcut: "↩") { save(p) }
    }
  }

  /// Validated inline: on a bad URL the field stays open with the reason (the main window may be closed). A good
  /// one is journaled like AppModel.markPosted: "<Platform> marked posted · Undo" toast, and ⌘Z undoes it.
  private func save(_ p: PlatformPost) {
    let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      model.splitEditorSession()
      let r = try model.bulk.record("mark-posted", ids: [p.videoId], plan: true) {
        try model.postActions.markPosted(postId: p.id, url: u, at: Date())
      }
      ChangeSignal.post()
      model.refresh()
      urlFor = nil
      urlError = nil
      url = ""
      let label = "\(p.platform.displayName) marked posted"
      if let b = r.batchId {
        model.undoHistory.push(b, label: label)
        model.show(DSToastModel(message: label, tone: .neutral, actionTitle: "Undo", action: { [model] in model.undo(batch: b) }, duration: 6))
      }
    } catch {
      urlError = error.localizedDescription
    }
  }

  // MARK: Attention rows

  private var problemsRow: some View {
    let n = state.problems.count
    return Button {
      WindowManager.shared.showMain(screen: .posts)
      model.reviewProblems()
    } label: {
      HStack(spacing: DS.space.xs) {
        Image(systemName: DSTone.danger.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.color.danger)
        Text("\(n) need\(n == 1 ? "s" : "") attention").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        Spacer(minLength: 0)
        Text("Review").font(DS.type.calloutMedium).foregroundStyle(DS.color.textSecondary)
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
      }
      .padding(.horizontal, DS.space.sm)
      .frame(height: 40)
      .background(DS.color.tint(.danger), in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .dsTooltip(model.problemSummary.detail)
  }

  private var engineRow: some View {
    Button {
      WindowManager.shared.showMain(screen: .health)
    } label: {
      HStack(spacing: DS.space.xs) {
        DSStatusDot(tone: .danger, size: 7)
        Text("Engine stopped").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        Text(state.lastTick.map { "ticked \(Fmt.relative($0, now: model.now))" } ?? "never ticked")
          .font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        Spacer(minLength: 0)
        Text("Health").font(DS.type.calloutMedium).foregroundStyle(DS.color.textSecondary)
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
      }
      .padding(.horizontal, DS.space.sm)
      .frame(height: 40)
      .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .dsTooltip("Nothing is posted or handed to you while the engine is stopped. Open Health to see why.")
  }

  /// "Update ready: 0.6.0 · Restart & update" / "Updating · Installing" / "Update blocked · Show why" (round 4 S5).
  @ViewBuilder private func updateRow(_ u: MenuBarState.UpdateRow) -> some View {
    switch u {
    case .ready(let v):
      HStack(spacing: DS.space.xs) {
        DSStatusDot(tone: .accent, size: 7)
        // The version goes first when space runs out (the button's tooltip names it too).
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DS.space.xs) {
            Text("Update ready").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
            Text(v).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          }
          Text("Update ready").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        DSButton("Restart & update", variant: .ghost, size: .sm, disabledReason: AutoUpdateUI.shared.actionBlockedReason,
                 tooltip: "Restart DJ Queue now and install \(v). Waits for any render to finish.") { AutoUpdateUI.shared.restartAndUpdate() }
          .fixedSize()
      }
      .padding(.leading, DS.space.sm)
      .padding(.trailing, DS.space.xxs)
      .frame(height: 40)
      .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    case .working(let label):
      HStack(spacing: DS.space.xs) {
        DSSpinner(size: 12, color: DS.color.textSecondary)
        Text("Updating").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        Text(label).font(DS.type.caption).foregroundStyle(DS.color.textSecondary).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DS.space.sm)
      .frame(height: 40)
      .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
      .dsTooltip("DJ Queue restarts by itself once the update is installed.")
    case .blocked(let v, let reason):
      Button {
        AutoUpdateUI.shared.showBlocked()
      } label: {
        HStack(spacing: DS.space.xs) {
          Image(systemName: DSTone.warning.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.color.warning)
          Text("Update blocked").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
          Text(v).font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
          Spacer(minLength: 0)
          Text("Show why").font(DS.type.calloutMedium).foregroundStyle(DS.color.textSecondary)
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.color.textTertiary)
        }
        .padding(.horizontal, DS.space.sm)
        .frame(height: 40)
        .background(DS.color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .dsTooltip("\(reason) Open DJ Queue to see the reason and the log.")
    }
  }

  // MARK: Footer

  @ViewBuilder private var footer: some View {
    if confirmPause {
      HStack(spacing: DS.space.xs) {
        Text("Pause all posting?").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
        Spacer(minLength: 0)
        DSButton("Cancel", variant: .ghost, size: .sm) { confirmPause = false }
        DSButton("Pause", variant: .outline, size: .sm, tooltip: "Stop handing out posts until you resume") {
          model.setPaused(true)
          confirmPause = false
        }
      }
      .padding(.horizontal, DS.space.md)
      .frame(height: 52)
    } else {
      HStack(spacing: DS.space.xs) {
        DSButton("Open DJ Queue", variant: .ghost, size: .sm, tooltip: "Open the main window", shortcut: "⌘0") {
          WindowManager.shared.showMain()
        }
        Spacer(minLength: 0)
        Text("Pause posting").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
        DSSwitch(isOn: Binding(get: { state.paused }, set: { on in
          if on { confirmPause = true } else { model.setPaused(false) }
        }), small: true)
        .dsTooltip(state.paused ? "Resume posting (switch off)" : "Pause all posting (asks first)")
        .accessibilityLabel("Pause posting")
        DSXMenuButton(tooltip: "Pause a platform, open Health or quit", size: .sm) {
          // Item titles say what a click does (native menu items show no tooltip); each change is undoable.
          Menu("Pause or resume one platform") {
            ForEach(model.settings.activePlatforms) { p in
              let paused = model.settings.pausedPlatforms.contains(p)
              Button(paused ? "Resume \(p.displayName) (paused)" : "Pause \(p.displayName)") { model.setPlatformPaused(p, !paused) }
            }
          }
          Button("Open Health", systemImage: "heart") { WindowManager.shared.showMain(screen: .health) }
          Divider()
          Section("The engine reopens it — stop it in Settings → Engine") {
            Button("Quit DJ Queue", systemImage: "power") { NSApp.terminate(nil) }
          }
        }
      }
      .padding(.leading, DS.space.xs)
      .padding(.trailing, DS.space.sm)
      .frame(height: 52)
    }
  }
}
