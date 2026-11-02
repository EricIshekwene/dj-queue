import AppKit
import DJQCore
import SwiftUI

/// MB.ICON: glyph + approved days ("5d"); red badge with count on errors; grey when the engine is stopped;
/// pause glyph when paused. Drawn at display time so the colours follow the menu bar's appearance.
enum MenuBarIcon {
  static func image(days: Int, errors: Int, engineOn: Bool, paused: Bool) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    let text = "\(days)d" as NSString
    let textSize = text.size(withAttributes: [.font: font])
    let symbolName = paused ? "pause.circle" : "play.square.stack"
    let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DJ Queue")?
      .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    let badgeText = errors > 9 ? "9+" : "\(errors)" as NSString
    let badgeFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    let badgeW = errors > 0 ? max(14, badgeText.size(withAttributes: [.font: badgeFont]).width + 7) : 0
    let symW = symbol?.size.width ?? 16
    let size = NSSize(width: ceil(symW + 4 + textSize.width + (errors > 0 ? badgeW + 3 : 0)), height: 18)
    let template = errors == 0
    let img = NSImage(size: size, flipped: false) { _ in
      let alpha: CGFloat = engineOn ? 1 : 0.4
      let ink = template ? NSColor.black.withAlphaComponent(alpha) : NSColor.labelColor.withAlphaComponent(alpha)
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
        let r = NSRect(x: size.width - badgeW, y: 2, width: badgeW, height: 14)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        let bs = badgeText.size(withAttributes: [.font: badgeFont])
        badgeText.draw(at: NSPoint(x: r.midX - bs.width / 2, y: r.midY - bs.height / 2),
                       withAttributes: [.font: badgeFont, .foregroundColor: NSColor.white])
      }
      return true
    }
    img.isTemplate = template
    img.accessibilityDescription = "DJ Queue: \(days) days approved\(errors > 0 ? ", \(errors) problems" : "")"
    return img
  }
}

struct MenuBarLabel: View {
  let host: AppHost
  var body: some View {
    if let m = host.model {
      Image(nsImage: MenuBarIcon.image(days: m.runway.approvedDays, errors: m.problems.count, engineOn: m.engineRunning, paused: m.settings.paused))
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
      VStack(alignment: .leading, spacing: 8) {
        Label("DJ Queue can't start", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        Text(host.startupError ?? "").font(DS.Font.secondary)
        Button("Quit") { NSApp.terminate(nil) }
      }
      .padding(14).frame(width: 320)
    }
  }
}

/// MB.S1–S3 (Bonsai popover ref): big runway number, next post, due rows, errors, footer.
struct MenuBarView: View {
  @Bindable var model: AppModel
  @State private var urlFor: String?
  @State private var url = ""
  @State private var urlError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      runway
      if !model.problems.isEmpty { errors }
      if let n = model.nextPost { next(n) }
      due
      Divider()
      footer
      engineLine
    }
    .padding(14)
    .frame(width: 320)
    .onAppear { model.popoverVisible = true; model.refresh() }
    .onDisappear { model.popoverVisible = false }
  }

  private var runway: some View {
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 0) {
        Text("\(model.runway.approvedDays)d")
          .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(model.runwayTint(model.runway.approvedDays, threshold: model.settings.approvedRunwayAlertDays))
        Text("approved").font(DS.Font.secondary).foregroundStyle(.secondary)
      }
      Spacer()
      RunwayNumber(days: model.runway.readyDays, label: "ready", emphasized: false)
      RunwayNumber(days: model.runway.totalDays, label: "total", emphasized: false).padding(.leading, 12)
    }
  }

  private var errors: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button { open(.posts); model.reviewProblems() } label: {
        HStack {
          Image(systemName: "exclamationmark.octagon.fill")
          Text(model.problemSummary.title).font(DS.Font.bodyStrong)
          Spacer()
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      ForEach(model.problems.prefix(3)) { p in
        HStack(spacing: 8) {
          PlatformGlyph(platform: p.platform, tint: .red, size: 18)
          Text(model.video(p.videoId).map(model.displayName) ?? "").font(DS.Font.body).lineLimit(1)
          Spacer()
          StatusPill(text: p.errorType?.displayName ?? p.state.displayName, tint: .red)
        }
      }
    }
  }

  private func next(_ p: PlatformPost) -> some View {
    HStack(spacing: 8) {
      Eyebrow("Next")
      Text(Fmt.shortTime(p.scheduledAt, tz: model.tz)).font(DS.Font.mono)
      PlatformGlyph(platform: p.platform, size: 16)
      Text(model.video(p.videoId).map(model.displayName) ?? "").font(DS.Font.body).lineLimit(1)
      Spacer()
      Text(model.dm.key(p.scheduledAt) == model.todayKey ? Fmt.relative(p.scheduledAt, now: model.now) : Fmt.day(p.scheduledAt, tz: model.tz, style: "EEE"))
        .font(DS.Font.secondary).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var due: some View {
    let rows = Array(model.dueNow.prefix(3))
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Eyebrow("Due now")
        ForEach(rows) { p in
          VStack(spacing: 6) {
            HStack(spacing: 8) {
              PlatformGlyph(platform: p.platform, size: 20)
              VStack(alignment: .leading, spacing: 0) {
                Text(model.video(p.videoId).map(model.displayName) ?? "").font(DS.Font.bodyStrong).lineLimit(1)
                Text(Fmt.shortTime(p.scheduledAt, tz: model.tz) + (p.scheduledAt < model.now ? " · \(Fmt.relative(p.scheduledAt, now: model.now))" : ""))
                  .font(DS.Font.secondary).foregroundStyle(p.state == .overdue ? Color.orange : .secondary)
              }
              Spacer()
              Button { model.copyCaption(p) } label: { Image(systemName: "text.quote") }.help("Copy caption")
                .accessibilityLabel("Copy caption")
              Button { urlFor = urlFor == p.id ? nil : p.id; url = ""; urlError = nil } label: { Image(systemName: "checkmark.circle") }
                .help("Mark posted").accessibilityLabel("Mark posted")
            }
            .buttonStyle(.borderless)
            if urlFor == p.id {
              HStack {
                TextField("Paste \(p.platform.shortName) URL", text: $url).textFieldStyle(.roundedBorder)
                  .onSubmit { save(p) }
                  .onChange(of: url) { urlError = nil }
                Button("Save") { save(p) }.disabled(url.isEmpty)
              }
              if let urlError {
                Label(urlError, systemImage: "exclamationmark.circle.fill").font(DS.Font.secondary).foregroundStyle(.red)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
      }
    }
  }

  /// Validated inline: on a bad URL the field stays open with the reason (the main window may be closed).
  private func save(_ p: PlatformPost) {
    let u = url.trimmingCharacters(in: .whitespaces)
    do {
      try model.postActions.markPosted(postId: p.id, url: u, at: Date())
      ChangeSignal.post()
      model.refresh()
      urlFor = nil
      urlError = nil
    } catch {
      urlError = error.localizedDescription
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Button("Open DJ Queue") { open(nil) }.buttonStyle(.borderedProminent)
      Spacer()
      Button(model.settings.paused ? "Resume" : "Pause all") { model.setPaused(!model.settings.paused) }
      Menu {
        ForEach(model.settings.activePlatforms) { p in
          Toggle(p.displayName, isOn: Binding(get: { model.settings.pausedPlatforms.contains(p) }, set: { model.setPlatformPaused(p, $0) }))
        }
      } label: { Image(systemName: "pause.circle") }
        .menuStyle(.borderlessButton).fixedSize().help("Pause one platform")
    }
  }

  private var engineLine: some View {
    HStack(spacing: 6) {
      StateDot(tint: model.engineRunning ? .green : .red, size: 7)
      Text(model.engineRunning ? "Engine running" : "Engine stopped").font(DS.Font.secondary).fixedSize()
      Text("ticked \(model.lastHeartbeat.map { Fmt.relative($0.at, now: model.now) } ?? "never")\(model.renderLine.map { " · \($0)" } ?? "")")
        .font(DS.Font.secondary).foregroundStyle(.secondary).lineLimit(1)
      Spacer()
      Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless)
        .help("Quit — the background engine restarts it automatically. To stop it, use Settings → Engine.")
        .accessibilityLabel("Quit")
    }
  }

  private func open(_ s: Screen?) {
    WindowManager.shared.showMain(screen: s)
  }
}
