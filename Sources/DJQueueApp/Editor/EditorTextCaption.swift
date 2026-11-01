import DJQCore
import SwiftUI

// MARK: - Text tab (E.S5)

struct EditorTextTab: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let r = model.resolved
    VStack(alignment: .leading, spacing: 0) {
      EditorSection("Text", accessory: { EditorInheritedTag(from: model.source(of: "text")) }) {
        if model.versionNo == 1, !r.hasText, !r.noText, !model.prefill.isEmpty { prefillCard }
        EditorTextArea(text: Binding(get: { r.text }, set: { t in model.updateVersion { $0.text = t } }),
                       placeholder: "Text on the video", height: 76, secondary: model.source(of: "text") != nil)
          .disabled(r.noText)
          .opacity(r.noText ? 0.5 : 1)
        Toggle("No text", isOn: Binding(get: { r.noText }, set: { v in model.updateVersion { $0.noText = v } }))
          .toggleStyle(.switch).controlSize(.small)
      }
      Divider()
      EditorSection("Style", accessory: { EditorInheritedTag(from: model.source(of: "style")) }) {
        HStack(spacing: 8) {
          ForEach(TextStyle.allCases, id: \.self) { s in styleTile(s, selected: r.style == s) }
        }
      }
      EditorSection("Size", accessory: {
        HStack(spacing: 6) {
          EditorInheritedTag(from: model.source(of: "size"))
          Text(sizeName(r.size)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
      }) {
        HStack(spacing: 8) {
          Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
          Slider(value: Binding(get: { r.size }, set: { v in model.updateVersion { $0.size = v.rounded() } }), in: 40...110)
          Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
        }
      }
      EditorSection("Alignment", accessory: { EditorInheritedTag(from: model.source(of: "align")) }) {
        Picker("", selection: Binding(get: { r.align }, set: { a in model.updateVersion { $0.align = a } })) {
          Image(systemName: "text.alignleft").tag(TextAlign.left)
          Image(systemName: "text.aligncenter").tag(TextAlign.center)
          Image(systemName: "text.alignright").tag(TextAlign.right)
        }
        .pickerStyle(.segmented).labelsHidden()
      }
      EditorSection("Position", accessory: { EditorInheritedTag(from: model.source(of: "posY")) }) {
        HStack {
          Text(abs(r.posX - 0.5) < 0.001 && abs(r.posY - 0.5) < 0.001 ? "Centre"
               : String(format: "%.0f%% across · %.0f%% down", r.posX * 100, r.posY * 100))
            .font(.system(size: 12))
          Spacer()
          Button("Centre") { model.updateVersion { $0.posX = 0.5; $0.posY = 0.5 } }
            .controlSize(.small).disabled(abs(r.posX - 0.5) < 0.001 && abs(r.posY - 0.5) < 0.001)
        }
        Text("Drag the text on the preview").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      EditorSection("Timing") {
        HStack {
          Text(r.textStart == nil && r.textEnd == nil ? "Whole clip"
               : "\(EditorGeometry.time(r.textStart ?? 0, tenths: true)) – \(EditorGeometry.time(r.textEnd ?? model.trim.duration, tenths: true))")
            .font(.system(size: 12))
          Spacer()
          Button("Whole clip") { model.updateVersion { $0.textStart = nil; $0.textEnd = nil } }
            .controlSize(.small).disabled(r.textStart == nil && r.textEnd == nil)
        }
        Text("Drag the ends of the text bar on the timeline").font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
  }

  private var prefillCard: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("From the tag").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        Text(model.prefill).font(.system(size: 13, weight: .semibold)).lineLimit(3)
      }
      Spacer()
      Button("Use") { model.updateVersion { $0.text = model.prefill; $0.noText = nil } }
        .buttonStyle(.borderedProminent).controlSize(.small)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
  }

  private func sizeName(_ s: Double) -> String { s < 54 ? "Small" : s <= 76 ? "Medium" : "Large" }

  private func styleTile(_ s: TextStyle, selected: Bool) -> some View {
    VStack(spacing: 4) {
      ZStack {
        RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
        sample(s)
      }
      .frame(height: 52)
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
      Text(s.displayName).font(.system(size: 10, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
    }
    .frame(maxWidth: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { model.updateVersion { $0.style = s } }
  }

  @ViewBuilder private func sample(_ s: TextStyle) -> some View {
    switch s {
    case .box:
      Text("Aa").font(.system(size: 15, weight: .heavy)).foregroundStyle(.black)
        .padding(.horizontal, 8).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 5).fill(.white))
    case .outline:
      ZStack {
        ForEach(0..<8, id: \.self) { i in
          let a = Double(i) * .pi / 4
          Text("Aa").font(.system(size: 17, weight: .heavy)).foregroundStyle(.black).offset(x: cos(a) * 1.5, y: sin(a) * 1.5)
        }
        Text("Aa").font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
      }
    case .shadow:
      Text("Aa").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.9), radius: 3, y: 1)
    }
  }
}

// MARK: - Caption tab (E.S8)

struct EditorCaptionTab: View {
  @ObservedObject var model: EditorModel
  @State private var extra = ""
  @State private var showOverrides = false

  var body: some View {
    let r = model.resolved
    VStack(alignment: .leading, spacing: 0) {
      EditorSection("Template", accessory: { EditorInheritedTag(from: model.source(of: "captionTemplateId")) }) {
        Picker("", selection: Binding(get: { r.captionTemplateId ?? "" },
                                      set: { id in model.updateVersion { $0.captionTemplateId = id.isEmpty ? nil : id } })) {
          if r.captionTemplateId == nil { Text("Choose a template…").tag("") }
          ForEach(model.templates) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        if r.captionTemplateId == nil && r.caption.isEmpty,
           let d = model.templates.first(where: { $0.id == model.settings.defaultCaptionTemplateId }) {
          Button("Use “\(d.name)”") { model.updateVersion { $0.captionTemplateId = d.id } }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
      }
      EditorSection("Caption", accessory: { EditorInheritedTag(from: model.source(of: "caption")) }) {
        EditorTextArea(text: Binding(get: { r.caption }, set: { c in model.updateVersion { $0.caption = c } }),
                       placeholder: model.caption(for: model.activePlatforms.last ?? .tiktok), height: 132,
                       secondary: model.source(of: "caption") != nil)
        EditorFlowLayout(spacing: 4) {
          ForEach(model.postingPlatforms) { p in count(p) }
        }
      }
      Divider()
      EditorSection("Hashtags", accessory: {
        if r.autoHashtags {
          EditorPill(text: "Auto", color: .accentColor, systemImage: "sparkles").help("Default sets + one rotating set for this video")
        } else {
          EditorInheritedTag(from: model.source(of: "hashtagSetIds"))
          Button("Auto") { model.updateVersion { $0.hashtagSetIds = nil } }.buttonStyle(.borderless).font(.system(size: 11))
            .disabled(model.versionNo > 1 && model.source(of: "hashtagSetIds") != nil)
        }
      }) {
        let inUse = model.setsInUse
        ForEach(categories, id: \.self) { cat in
          VStack(alignment: .leading, spacing: 4) {
            Text(cat.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            EditorFlowLayout(spacing: 5) {
              ForEach(model.sets.filter { $0.category == cat }) { s in chip(s, on: inUse.contains(s.id), inUse: inUse) }
            }
          }
        }
        TextField("Extra hashtags", text: $extra)
          .textFieldStyle(.roundedBorder)
          .onSubmit(commitExtra)
          .onChange(of: extra) { _, _ in commitExtra() }
        let tags = model.hashtags
        if !tags.isEmpty {
          Text(tags.joined(separator: " ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
        }
      }
      Divider()
      EditorSection("YouTube title", accessory: {
        let n = (r.youtubeTitle.isEmpty ? model.youtubeTitleDefault : r.youtubeTitle).count
        Text("\(n)/100").font(.system(size: 11, design: .monospaced)).foregroundStyle(n > 100 ? .orange : .secondary)
      }) {
        TextField(model.youtubeTitleDefault, text: Binding(get: { r.youtubeTitle },
                                                           set: { t in model.updateVersion { $0.youtubeTitle = String(t.prefix(100)) } }))
          .textFieldStyle(.roundedBorder)
      }
      Divider()
      DisclosureGroup(isExpanded: $showOverrides) {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(model.activePlatforms) { p in overrideRow(p, r) }
        }
        .padding(.top, 8)
      } label: {
        HStack {
          Text("Per-platform captions").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
          if !r.platformCaptions.isEmpty { EditorPill(text: "\(r.platformCaptions.count)", color: .accentColor) }
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
    }
    .onAppear {
      extra = r.extraHashtags.joined(separator: " ")
      showOverrides = !r.platformCaptions.isEmpty
    }
    .onChange(of: model.versionNo) { _, _ in extra = model.resolved.extraHashtags.joined(separator: " ") }
    .onChange(of: model.videoId) { _, _ in extra = model.resolved.extraHashtags.joined(separator: " ") }
  }

  private var categories: [String] {
    var seen = Set<String>()
    return model.sets.map(\.category).filter { seen.insert($0).inserted }
  }

  private func commitExtra() {
    let tags = extra.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline }).map(String.init)
    guard tags != model.resolved.extraHashtags else { return }
    model.updateVersion { $0.extraHashtags = tags }
  }

  private func count(_ p: Platform) -> some View {
    let n = model.caption(for: p).count
    let lim = model.settings.limits[p]?.captionLimit ?? 2200
    return EditorPill(text: "\(p.shortName) \(n)/\(lim)\(n > lim ? " ⚠" : "")", color: n > lim ? .orange : .secondary)
  }

  private func chip(_ s: HashtagSet, on: Bool, inUse: Set<String>) -> some View {
    HStack(spacing: 4) {
      Text(s.name).font(.system(size: 11, weight: on ? .semibold : .regular))
      Image(systemName: on ? "xmark" : "plus").font(.system(size: 8, weight: .bold))
    }
    .padding(.horizontal, 8).padding(.vertical, 4)
    .foregroundStyle(on ? Color.accentColor : Color.primary)
    .background(Capsule().fill(on ? Color.accentColor.opacity(0.14) : Color.clear))
    .overlay(Capsule().strokeBorder(on ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1))
    .contentShape(Capsule())
    .onTapGesture {
      // Choosing turns Auto off: start from what is in use now, in set order.
      var ids = model.sets.map(\.id).filter { inUse.contains($0) }
      if on { ids.removeAll { $0 == s.id } } else { ids.append(s.id) }
      model.updateVersion { $0.hashtagSetIds = ids }
    }
    .help(s.tags.joined(separator: " "))
  }

  @ViewBuilder private func overrideRow(_ p: Platform, _ r: ResolvedVersion) -> some View {
    let on = r.platformCaptions[p] != nil
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: Binding(get: { on }, set: { v in
        var m = r.platformCaptions
        m[p] = v ? model.caption(for: p) : nil
        model.updateVersion { $0.platformCaptions = m }
      })) {
        HStack(spacing: 6) { EditorPlatformBadge(platform: p); Text(p.displayName).font(.system(size: 12)) }
      }
      .toggleStyle(.switch).controlSize(.mini)
      if on {
        EditorTextArea(text: Binding(get: { r.platformCaptions[p] ?? "" }, set: { t in
          var m = model.resolved.platformCaptions
          m[p] = t
          model.updateVersion { $0.platformCaptions = m }
        }), placeholder: "Caption for \(p.displayName)", height: 80)
      }
    }
  }
}
