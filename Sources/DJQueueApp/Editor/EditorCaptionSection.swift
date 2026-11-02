import DJQCore
import SwiftUI

/// Caption (#6): composer-style caption field, ONE labelled length line, warnings only for platforms near or over
/// their limit — with explicit "Drop hashtags for X" / "Write an X caption" — hashtag sets, YouTube title and
/// per-platform captions. Nothing is shortened silently (#9).
struct EditorCaptionSection: View {
  @ObservedObject var model: EditorModel
  @State private var extra = ""
  @State private var showOwn = false

  var body: some View {
    let r = model.resolved
    EditorSectionView(.caption) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        template(r)
        caption(r)
        hashtags(r)
        youtube(r)
        ownCaptions(r)
      }
    }
    .onAppear { syncDrafts() }
    .onChange(of: model.versionNo) { _, _ in syncDrafts() }
    .onChange(of: model.videoId) { _, _ in syncDrafts() }
    .onChange(of: model.resolved.extraHashtags) { _, tags in
      // Reset / version switch / undo: re-sync the field unless it already says the same thing.
      if parse(extra) != tags { extra = tags.joined(separator: " ") }
    }
    .onChange(of: model.openPlatformCaption) { _, p in if p != nil { showOwn = true } }
  }

  private func syncDrafts() {
    let r = model.resolved
    extra = r.extraHashtags.joined(separator: " ")
    showOwn = !r.platformCaptions.isEmpty
  }

  private func resetter(_ f: [String]) -> (() -> Void)? { model.ownsField(f) ? { model.resetVersion(f) } : nil }

  // MARK: Template

  private func template(_ r: ResolvedVersion) -> some View {
    let def = model.templates.first { $0.id == model.defaults.captionTemplateId }?.name ?? model.defaults.captionTemplateId
    var options = [DSSelectOption(value: "", title: "Default · \(def)")]
    options += model.templates.map { DSSelectOption(value: $0.id, title: $0.name) }
    return EditorField(label: "Template", help: "Used when no caption is typed below", isCustom: !r.isDefault("captionTemplateId"),
                       inheritedFrom: model.source(of: "captionTemplateId"), resetHelp: "Back to the default template",
                       onReset: resetter(["captionTemplateId"])) {
      DSSelect(selection: Binding(get: { r.captionTemplateId ?? "" },
                                  set: { id in model.setCaptionTemplate(id) }),
               options: options, size: .sm,
               disabledReason: r.caption.isEmpty ? nil : "A typed caption is used instead — clear it to use a template")
    }
  }

  // MARK: Caption + length line + warnings

  private func caption(_ r: ResolvedVersion) -> some View {
    EditorField(label: "Caption", isCustom: !r.isDefault("caption"), inheritedFrom: model.source(of: "caption"),
                resetHelp: "Delete the typed caption; use the template", onReset: resetter(["caption"])) {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        DSTextArea(placeholder: model.mainCaption,
                   text: Binding(get: { r.caption }, set: { c in model.updateVersion { $0.caption = c } }),
                   minHeight: 104, maxHeight: 220)
        lengthLine(r)
        ForEach(model.captionWarnings) { w in warning(w) }
      }
    }
  }

  private func lengthLine(_ r: ResolvedVersion) -> some View {
    let n = model.mainCaption.count
    return HStack(spacing: 5) {
      Text("\(n) characters").font(DS.type.caption.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
      if r.caption.isEmpty {
        Text("· from the template").font(DS.type.caption).foregroundStyle(DS.color.textTertiary)
      }
      Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(DS.color.textTertiary)
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .dsTooltip(breakdownShort)
    .accessibilityElement(children: .combine)
    .accessibilityHint(breakdown)
  }

  /// Full per-platform breakdown for the tooltip ("TikTok 182 / 4000 …").
  private var breakdown: String {
    let lines = model.postingPlatforms.map { p in
      let n = model.caption(for: p).count
      let own = model.resolved.platformCaptions[p] != nil ? " (own caption)" : ""
      return "\(p.displayName): \(n) / \(model.captionLimit(p))\(own)"
    }
    return lines.isEmpty ? "Not posting anywhere" : lines.joined(separator: "\n")
  }

  /// Compact one-paragraph form for the hover bubble ("TikTok 182/4000 · Instagram 182/2200 …").
  private var breakdownShort: String {
    let items = model.postingPlatforms.map { p in
      "\(p.editorShortName) \(model.caption(for: p).count)/\(model.captionLimit(p))\(model.resolved.platformCaptions[p] != nil ? " (own)" : "")"
    }
    return items.isEmpty ? "Not posting anywhere" : items.joined(separator: " · ")
  }

  private func warning(_ w: EditorCaptionWarning) -> some View {
    let name = w.platform.displayName
    let dropReason: String? = {
      guard let bare = w.countWithoutHashtags else { return "\(name)'s caption has no hashtags to drop" }
      return bare > w.limit ? "Still \(bare)/\(w.limit) without hashtags — write a shorter \(name) caption" : nil
    }()
    return VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(spacing: 6) {
        Image(systemName: w.over ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
          .font(.system(size: 11, weight: .semibold))
        Text(w.over ? "Too long for \(name)" : "Close to the \(name) limit").font(DS.type.captionMedium)
        Text("· \(w.count)/\(w.limit)").font(DS.type.caption.monospacedDigit())
        Spacer(minLength: 0)
      }
      .foregroundStyle(w.over ? DS.color.warning : DS.color.textSecondary)
      if w.over {
        DSFlowLayout(spacing: 6) {
          DSButton("Drop hashtags for \(name)", variant: .outline, size: .sm, disabledReason: dropReason,
                   tooltip: "Give \(name) the same caption without hashtags (\(w.countWithoutHashtags ?? 0) characters)") {
            model.dropHashtags(w.platform)
          }
          DSButton("Write a\(name.first.map { "AEIOUX".contains($0) } == true ? "n" : "") \(name) caption", variant: .ghost, size: .sm,
                   tooltip: "Start a caption just for \(name) from this one") { model.writePlatformCaption(w.platform) }
        }
      }
    }
    .padding(.horizontal, DS.space.sm).padding(.vertical, DS.space.xs)
    .background(w.over ? DS.color.warningTint : DS.color.surfaceSunken,
                in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
  }

  // MARK: Hashtags

  private var categories: [String] {
    var seen = Set<String>()
    return model.sets.map(\.category).filter { seen.insert($0).inserted }
  }

  private func hashtags(_ r: ResolvedVersion) -> some View {
    EditorField(label: "Hashtags", isCustom: !r.isDefault("hashtagSetIds") || !r.isDefault("extraHashtags"),
                inheritedFrom: model.source(of: "hashtagSetIds"), resetHelp: "Back to the default sets; clear extra tags",
                onReset: resetter(["hashtagSetIds", "extraHashtags"])) {
      VStack(alignment: .leading, spacing: DS.space.xs) {
        ForEach(categories, id: \.self) { cat in
          VStack(alignment: .leading, spacing: 4) {
            Text(cat).font(DS.type.micro).foregroundStyle(DS.color.textTertiary)
            DSFlowLayout(spacing: 5) {
              ForEach(model.sets.filter { $0.category == cat }) { s in
                let on = r.hashtagSetIds.contains(s.id)
                DSChip(s.name, isSelected: on, size: .sm) {
                  var ids = model.sets.map(\.id).filter { r.hashtagSetIds.contains($0) }
                  if on { ids.removeAll { $0 == s.id } } else { ids.append(s.id) }
                  model.setHashtagSets(ids)
                }
                .dsTooltip(s.tags.isEmpty ? "This set has no hashtags yet"
                           : on ? "Remove \(s.tags.joined(separator: " ")) from this caption"
                           : "Add \(s.tags.joined(separator: " ")) to this caption")
              }
            }
          }
        }
        DSTextField(placeholder: "Extra hashtags, e.g. #afrohouse", text: $extra, size: .sm, onSubmit: commitExtra)
          .onChange(of: extra) { _, _ in commitExtra() }
          .dsTooltip("Added after the sets, separated by spaces", shortcut: "↩")
        if !model.hashtags.isEmpty {
          Text(model.hashtags.joined(separator: " ")).font(DS.type.caption).foregroundStyle(DS.color.textTertiary).lineLimit(3)
        }
      }
    }
  }

  private func parse(_ s: String) -> [String] {
    s.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline }).map(String.init)
  }

  private func commitExtra() {
    let tags = parse(extra)
    guard tags != model.resolved.extraHashtags else { return }
    model.setExtraHashtags(tags)
  }

  // MARK: YouTube title

  private func youtube(_ r: ResolvedVersion) -> some View {
    let lim = model.settings.limits[.youtube]?.titleLimit ?? 100
    return EditorField(label: "YouTube title", help: "The Shorts title (YouTube shows it under the handle)",
                       isCustom: !r.isDefault("youtubeTitle"), inheritedFrom: model.source(of: "youtubeTitle"),
                       resetHelp: "Back to the template (\(model.defaults.youtubeTitleTemplate))", onReset: resetter(["youtubeTitle"])) {
      VStack(alignment: .leading, spacing: 4) {
        DSTextField(placeholder: model.youtubeTitleDefault,
                    text: Binding(get: { r.youtubeTitle }, set: { t in model.updateVersion { $0.youtubeTitle = t } }),
                    hint: r.youtubeTitle.isEmpty ? "From the template “\(model.defaults.youtubeTitleTemplate)”" : nil,
                    limit: lim, size: .sm)
        if !model.posting(.youtube) { EditorHint("Not posting on YouTube Shorts.") }
      }
    }
  }

  // MARK: Per-platform captions

  private func ownCaptions(_ r: ResolvedVersion) -> some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      Button { dsWithAnimation { showOwn.toggle() } } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(showOwn ? 90 : 0))
          Text("Captions for one platform").font(DS.type.calloutMedium)
          if !r.platformCaptions.isEmpty { DSBadge("\(r.platformCaptions.count)", style: .soft(.neutral), size: .sm, help: r.platformCaptions.count == 1 ? "1 platform has its own caption" : "\(r.platformCaptions.count) platforms have their own caption") }
          Spacer(minLength: 0)
        }
        .foregroundStyle(DS.color.text)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .dsTooltip(showOwn ? "Hide the per-platform captions" : "Give a platform its own caption")
      if showOwn {
        VStack(alignment: .leading, spacing: DS.space.sm) {
          ForEach(model.postingPlatforms) { p in ownRow(p, r) }
        }
        .padding(.top, 4)
      }
    }
  }

  @ViewBuilder private func ownRow(_ p: Platform, _ r: ResolvedVersion) -> some View {
    let on = r.platformCaptions[p] != nil
    VStack(alignment: .leading, spacing: 6) {
      DSToggle(p.displayName, isOn: Binding(get: { on }, set: { v in
        model.setPlatformCaption(p, v ? model.caption(for: p) : nil)
      }), size: .sm)
      .dsTooltip(on ? "Delete \(p.displayName)'s own caption; use the shared one" : "Write a caption just for \(p.displayName)")
      if on {
        DSTextArea(placeholder: "Caption for \(p.displayName)",
                   text: Binding(get: { model.resolved.platformCaptions[p] ?? "" }, set: { t in model.setPlatformCaption(p, t) }),
                   limit: model.captionLimit(p), minHeight: 72, maxHeight: 160)
      }
    }
  }
}
