import DJQCore
import SwiftUI

/// DESIGN-v2 §7 inspector: a 340 pt floating card (r.lg, e1) with a sticky mini-index and ONE scrolling column —
/// Title · Frame · Text · Caption · Cover · Platforms, split by hairlines. No tabs, so nothing missing is hidden.
struct EditorInspector: View {
  @ObservedObject var model: EditorModel
  @State private var current: EditorSection = .title
  static let groupFormAnchor = "editor.groupForm"

  var body: some View {
    VStack(spacing: 0) {
      EditorMiniIndex(current: current, flagged: flagged) { s in
        current = s
        model.scrollTarget = s
      }
      .padding(.horizontal, DS.space.xs).padding(.vertical, DS.space.xs)
      DSSeparator()
      ScrollViewReader { proxy in
        ScrollView {
          // Full-width hairlines between sections (the Framer / Webflow / Figma inspector pattern) so each section
          // reads as its own block.
          VStack(alignment: .leading, spacing: 0) {
            EditorTitleSection(model: model)
            DSSeparator()
            EditorFrameSection(model: model)
            DSSeparator()
            EditorTextSection(model: model)
            DSSeparator()
            EditorCaptionSection(model: model)
            DSSeparator()
            EditorCoverSection(model: model)
            DSSeparator()
            EditorPlatformsSection(model: model)
          }
          .padding(.bottom, DS.space.xxl)
          .disabled(model.readOnly || model.video == nil)
          .dsTooltip(nil, disabledReason: model.readOnly ? EditorView.readOnlyReason : nil)
        }
        .scrollIndicators(.automatic)
        .onAppear { if let t = model.scrollTarget { jump(proxy, t, animated: false) } }
        .onChange(of: model.scrollTarget) { _, t in if let t { jump(proxy, t, animated: true) } }
        // The group form can open below the fold when New group sits at the bottom edge.
        .onChange(of: model.groupForm == nil) { _, closed in
          guard !closed else { return }
          DispatchQueue.main.async { dsWithAnimation { proxy.scrollTo(Self.groupFormAnchor, anchor: .bottom) } }
        }
      }
    }
    .frame(width: DS.size.inspectorWidth)
    .background(DS.color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous))
    .dsBorder(radius: DS.radius.lg)
    .dsElevation(DS.elevation.e1)
  }

  private func jump(_ proxy: ScrollViewProxy, _ s: EditorSection, animated: Bool) {
    current = s
    if animated { dsWithAnimation { proxy.scrollTo(s, anchor: .top) } } else { proxy.scrollTo(s, anchor: .top) }
    DispatchQueue.main.async { model.scrollTarget = nil }
  }

  /// Sections that hold a validation problem get a small warning dot in the index.
  private var flagged: Set<EditorSection> { Set(model.liveIssues.compactMap { EditorModel.section(for: $0.kind) }) }
}

/// Compact text index (caption size, so all six fit in 340 pt). Selected = soft grey capsule; a warning dot marks
/// sections that need attention.
struct EditorMiniIndex: View {
  var current: EditorSection
  var flagged: Set<EditorSection>
  var go: (EditorSection) -> Void
  @State private var hovering: EditorSection?

  var body: some View {
    HStack(spacing: 0) {
      ForEach(EditorSection.allCases) { s in
        Button { go(s) } label: {
          HStack(spacing: 3) {
            Text(s.rawValue).fixedSize()
            if flagged.contains(s) { Circle().fill(DS.color.warning).frame(width: 5, height: 5) }
          }
          .font(DS.type.captionMedium)
          .foregroundStyle(current == s || hovering == s ? DS.color.text : DS.color.textSecondary)
          .padding(.horizontal, 6).frame(height: 26)
          .background {
            if current == s { Capsule().fill(DS.color.selected) } else if hovering == s { Capsule().fill(DS.color.hover) }
          }
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? s : (hovering == s ? nil : hovering) }
        .dsTooltip(flagged.contains(s) ? "Jump to \(s.rawValue) (needs attention)" : "Jump to \(s.rawValue)", side: .bottom)
        .background(ScriptAnchor("Index \(s.rawValue)"))
        if s != EditorSection.allCases.last { Spacer(minLength: 0) }
      }
    }
  }
}

/// E.S4: versions v1…vn with usage, duplicate and delete (popover from the header's version picker).
struct EditorVersionList: View {
  @ObservedObject var model: EditorModel
  /// Asks before deleting (the header closes this popover and shows the confirmation).
  var requestDelete: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Versions").font(DS.type.headline).foregroundStyle(DS.color.text)
        .padding(.horizontal, DS.space.sm).padding(.top, DS.space.sm).padding(.bottom, DS.space.xxs)
      Text("A new version changes the text and caption for a repost. Empty fields carry forward from the version before.")
        .font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.space.sm).padding(.bottom, DS.space.xs)
      ForEach(model.versionNumbers, id: \.self) { n in row(n) }
      DSSeparator().padding(.vertical, DS.space.xxs)
      DSButton("New version", icon: "plus", variant: .ghost, size: .sm,
               disabledReason: model.readOnly ? "Editing is off for this clip" : nil,
               tooltip: "Start a new text version for a repost") { model.newVersion(copying: nil) }
        .padding(.horizontal, DS.space.xxs).padding(.bottom, DS.space.xs)
    }
    .padding(DS.space.xxs)
    .frame(width: 300)
    .background(DS.color.surfaceRaised)
  }

  private func row(_ n: Int) -> some View {
    let u = model.usage(of: n)
    let selected = n == model.versionNo
    return HStack(spacing: DS.space.xs) {
      Text("v\(n)").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text).frame(width: 26, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        if !u.posted.isEmpty { Text("Posted on " + u.posted.map(\.displayName).joined(separator: ", ")) }
        if !u.planned.isEmpty { Text("Planned on " + u.planned.map(\.displayName).joined(separator: ", ")) }
        if u.posted.isEmpty && u.planned.isEmpty { Text(n == 1 ? "Not posted yet" : "Not used yet") }
      }
      .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      Spacer()
      if selected { DSBadge("Editing", style: .soft(.neutral), size: .sm, help: "The version you're editing") }
      Menu {
        Button("Duplicate as new version") { model.newVersion(copying: n) }
        if n > 1 { Button("Delete v\(n)…", role: .destructive) { requestDelete(n) } }
      } label: { Image(systemName: "ellipsis").foregroundStyle(DS.color.textSecondary) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .dsTooltip("More actions for v\(n)")
    }
    .padding(.horizontal, DS.space.sm).frame(height: 40)
    .background(selected ? DS.color.selected : .clear, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { model.selectVersion(n) }
    .dsTooltip(selected ? nil : "Edit v\(n)'s text and caption")
  }
}
