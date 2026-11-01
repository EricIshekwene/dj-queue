import DJQCore
import SwiftUI

/// E.S3: right inspector (320 pt) — segmented Frame / Text / Caption / Cover + version picker.
struct EditorInspector: View {
  @ObservedObject var model: EditorModel
  @State private var showVersions = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Picker("", selection: $model.tab) {
          ForEach(EditorTab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        Button { showVersions.toggle() } label: {
          HStack(spacing: 3) {
            Text("v\(model.versionNo)").font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
          }
          .padding(.horizontal, 8).frame(height: 22)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Versions")
        .accessibilityLabel("Version \(model.versionNo), choose version")
        .popover(isPresented: $showVersions, arrowEdge: .bottom) { EditorVersionList(model: model) }
      }
      .padding(.horizontal, 12).frame(height: 44)
      Divider()
      ScrollView {
        Group {
          switch model.tab {
          case .frame: EditorFrameTab(model: model)
          case .text: EditorTextTab(model: model)
          case .caption: EditorCaptionTab(model: model)
          case .cover: EditorCoverTab(model: model)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 320)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

/// E.S4: versions v1…vn with usage, duplicate and delete.
struct EditorVersionList: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Versions").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
      ForEach(model.versionNumbers, id: \.self) { n in row(n) }
      Divider().padding(.vertical, 6)
      HStack {
        Button { model.newVersion(copying: nil) } label: { Label("New version", systemImage: "plus") }
          .buttonStyle(.borderless)
        Spacer()
      }
      .padding(.horizontal, 12)
      Text("Empty fields carry forward from the version before.")
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
    }
    .frame(width: 300)
  }

  private func row(_ n: Int) -> some View {
    let u = model.usage(of: n)
    let selected = n == model.versionNo
    return HStack(spacing: 8) {
      Text("v\(n)").font(.system(size: 13, weight: .semibold)).frame(width: 26, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        if !u.posted.isEmpty {
          Text("Posted on " + u.posted.map(\.shortName).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.green)
        }
        if !u.planned.isEmpty {
          Text("Planned " + u.planned.map(\.shortName).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.blue)
        }
        if u.posted.isEmpty && u.planned.isEmpty {
          Text(n == 1 ? "Not posted yet" : "Not used yet").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if selected { EditorPill(text: "Editing", color: .accentColor) }
      Menu {
        Button("Duplicate") { model.newVersion(copying: n) }
        if n > 1 { Button("Delete", role: .destructive) { model.deleteVersion(n) } }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Actions for v\(n)")
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.1) : .clear).padding(.horizontal, 6))
    .contentShape(Rectangle())
    .onTapGesture { model.selectVersion(n) }
  }
}

// MARK: - Frame tab (E.S1 controls, kind, platforms + skip, trim summary)

struct EditorFrameTab: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EditorSection("Kind") {
        Picker("", selection: Binding(get: { model.video?.kind ?? .djVid }, set: { model.setKind($0) })) {
          ForEach(Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
      }
      Divider()
      EditorSection("Aspect") {
        Picker("", selection: Binding(get: { model.edit.aspect }, set: { model.setAspect($0) })) {
          ForEach(Aspect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
      }
      EditorSection("Zoom", accessory: {
        Text(String(format: "%.2f×", model.zoom)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
      }) {
        HStack(spacing: 8) {
          Button { model.setZoom(model.zoom / 1.1) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless)
            .accessibilityLabel("Zoom out")
          Slider(value: Binding(get: { model.zoom }, set: { model.setZoom($0) }), in: 1...EditorGeometry.maxZoom)
          Button { model.setZoom(model.zoom * 1.1) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless)
            .accessibilityLabel("Zoom in")
        }
        if model.upscale > 1.01 {
          EditorPill(text: String(format: "Upscaled %.1f×", model.upscale), color: .orange, systemImage: "exclamationmark.triangle.fill")
        }
      }
      EditorSection("Crop", accessory: {
        if model.cropIsSet {
          Button("Centre") {
            let c = model.crop
            model.setCrop(CropRect(x: (model.sourceSize.width - c.w) / 2, y: (model.sourceSize.height - c.h) / 2, w: c.w, h: c.h))
          }
          .buttonStyle(.borderless).font(.system(size: 11))
        }
      }) {
        HStack(spacing: 8) {
          if model.cropIsSet {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
              .accessibilityLabel("Crop set")
          }
          Text("\(Int(model.crop.w)) × \(Int(model.crop.h)) px").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          Spacer()
        }
        Text("Drag the frame to move · scroll or pinch to zoom").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Divider()
      EditorSection("Platforms") {
        VStack(spacing: 6) {
          ForEach(model.activePlatforms) { p in platformRow(p) }
        }
      }
    }
  }

  private func platformRow(_ p: Platform) -> some View {
    let skipped = model.edit.skippedPlatforms.contains(p)
    let d = model.edit.trim(duration: model.duration, platform: p).duration
    let lim = model.settings.limits[p]?.maxDuration ?? .infinity
    let over = d > lim + 0.05
    return HStack(spacing: 8) {
      EditorPlatformBadge(platform: p, color: skipped ? .secondary : over ? .orange : .primary)
      Text(p.displayName).font(.system(size: 12)).foregroundStyle(skipped ? .secondary : .primary)
      Spacer()
      if !skipped {
        Text("\(Validation.fmt(d)) / \(Validation.fmt(lim))").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(over ? .orange : .secondary)
        if over && model.edit.platformTrims[p] == nil {
          Button("Trim") { model.addPlatformTrim(p) }.controlSize(.mini)
        }
      }
      Toggle("", isOn: Binding(get: { !skipped }, set: { on in
        model.updateEdit { if on { $0.skippedPlatforms.remove(p) } else { $0.skippedPlatforms.insert(p) } }
      }))
      .toggleStyle(.switch).controlSize(.mini).labelsHidden()
      .help(skipped ? "Skipped — turn on to post here" : "Turn off to skip this platform")
    }
    .frame(height: 22)
  }
}

// MARK: - Cover tab (E.S7)

struct EditorCoverTab: View {
  @ObservedObject var model: EditorModel
  @StateObject private var strip = EditorFrameStrip()
  @State private var cover: CGImage?

  private var coverTime: Double { model.edit.coverTime ?? model.trim.start }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EditorSection("Cover", accessory: {
        if model.edit.coverTime != nil {
          Button("First frame") { model.updateEdit { $0.coverTime = nil } }.buttonStyle(.borderless).font(.system(size: 11))
        }
      }) {
        HStack {
          Spacer()
          ZStack {
            EditorCroppedImage(image: cover, crop: model.crop, source: model.sourceSize)
            if model.edit.coverIncludesText, let o = model.overlay { Image(decorative: o, scale: 1).resizable() }
          }
          .aspectRatio(model.edit.aspect.ratio, contentMode: .fit)
          .frame(height: 260)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
          Spacer()
        }
        Text(model.edit.coverTime == nil ? "First frame of the trim · \(EditorGeometry.time(coverTime, tenths: true))"
             : "Frame at \(EditorGeometry.time(coverTime, tenths: true))")
          .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
      }
      EditorSection("Pick a frame") {
        HStack(spacing: 3) {
          let nearest = strip.frames.indices.min { abs(strip.frames[$0].time - coverTime) < abs(strip.frames[$1].time - coverTime) }
          ForEach(Array(strip.frames.enumerated()), id: \.offset) { i, f in
            let sel = i == nearest
            EditorCroppedImage(image: f.image, crop: model.crop, source: model.sourceSize)
              .aspectRatio(model.edit.aspect.ratio, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 3))
              .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(sel ? Color.accentColor : .clear, lineWidth: 2))
              .onTapGesture { setCover(f.time) }
          }
          if strip.frames.isEmpty { Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 50) }
        }
        Slider(value: Binding(get: { coverTime }, set: { setCover($0) }),
               in: model.trim.start...max(model.trim.end - 0.05, model.trim.start + 0.1))
        Button { setCover(model.playback.time) } label: { Label("Use playhead frame", systemImage: "scope") }
          .buttonStyle(.borderless).font(.system(size: 12))
      }
      Divider()
      EditorSection("Text") {
        Toggle("Include text on cover", isOn: Binding(get: { model.edit.coverIncludesText },
                                                      set: { v in model.updateEdit { $0.coverIncludesText = v } }))
        .toggleStyle(.switch).controlSize(.small)
      }
    }
    .onAppear { reload() }
    .onChange(of: model.trim) { _, _ in reload() }
    .onChange(of: coverTime) { _, _ in loadCover() }
  }

  private func setCover(_ t: Double) {
    let tr = model.trim
    let c = min(max(t, tr.start), tr.end)
    model.updateEdit { $0.coverTime = abs(c - tr.start) < 0.01 ? nil : c }
    model.playback.pause()
    model.playback.seek(c, exact: true)
  }

  private func reload() {
    strip.load(url: model.fileMissing ? nil : model.fileURL, from: model.trim.start, to: model.trim.end, count: 8,
               sync: model.snapshotMode)
    loadCover()
  }

  private func loadCover() {
    guard let url = model.fileURL, !model.fileMissing else { cover = nil; return }
    let t = coverTime
    if model.snapshotMode { cover = Media.frame(url, at: t, maxSize: CGSize(width: 1920, height: 1080)); return }
    Task.detached(priority: .userInitiated) {
      let img = Media.frame(url, at: t, maxSize: CGSize(width: 1920, height: 1080))
      await MainActor.run { if abs(t - coverTime) < 0.001 { cover = img } }
    }
  }
}
