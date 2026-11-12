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
      EditorMiniIndex(sections: EditorSection.inspector(photo: model.isPhoto), current: current, flagged: flagged) { s in
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
            if !model.isPhoto, model.versionNumbers.count > 1 || model.isRepostReady(model.versionNo) {
              EditorRepostReadyRow(model: model)
              DSSeparator()
            }
            // Fields go off section by section, not on this column: the collapsible rows must still open on a read-only clip.
            EditorTitleSection(model: model).disabled(model.fieldsOff)
            DSSeparator()
            EditorFrameSection(model: model)
            DSSeparator()
            EditorTextSection(model: model)
            DSSeparator()
            EditorCaptionSection(model: model).disabled(model.fieldsOff)
            DSSeparator()
            // Round 21 (D15): a photo post has no Cover section; the strip marks its first photo as the cover.
            if !model.isPhoto {
              EditorCoverSection(model: model)
              DSSeparator()
            }
            EditorPlatformsSection(model: model).disabled(model.fieldsOff)
          }
          .padding(.bottom, DS.space.xxl)
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
    // The photos strip isn't in this column: it flashes by itself (`EditorModel.flashPhotos`).
    guard s != .photos else { DispatchQueue.main.async { model.scrollTarget = nil }; return }
    current = s
    if animated && !dsAnimationsOff { dsWithAnimation { proxy.scrollTo(s, anchor: .top) } } else { proxy.scrollTo(s, anchor: .top) }
    DispatchQueue.main.async { model.scrollTarget = nil }
  }

  /// Sections that hold a validation problem get a small warning dot in the index.
  private var flagged: Set<EditorSection> { Set(model.liveIssues.compactMap { EditorModel.section(for: $0.kind) }) }
}

/// Compact text index (caption size, so all six fit in 340 pt). Selected = soft grey capsule; a warning dot marks
/// sections that need attention.
struct EditorMiniIndex: View {
  var sections: [EditorSection] = EditorSection.inspector(photo: false)
  var current: EditorSection
  var flagged: Set<EditorSection>
  var go: (EditorSection) -> Void
  @State private var hovering: EditorSection?

  var body: some View {
    HStack(spacing: 0) {
      ForEach(sections) { s in
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
        if s != sections.last { Spacer(minLength: 0) }
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
      Text("Each version is its own copy for a repost: editing one never changes another. Trim, crop and cover are shared by every version. Turn on each version that's ready to repost.")
        .font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.space.sm).padding(.bottom, DS.space.xs)
      ForEach(model.versionNumbers, id: \.self) { n in row(n) }
      DSSeparator().padding(.vertical, DS.space.xxs)
      DSButton("New version from v\(model.versionNo)", icon: "plus", variant: .ghost, size: .sm,
               disabledReason: model.readOnly ? "Editing is off for this clip" : nil,
               tooltip: "Copy v\(model.versionNo) as a new version. From then on, editing one never changes the other.") { model.newVersion(copying: nil) }
        .padding(.horizontal, DS.space.xxs).padding(.bottom, DS.space.xs)
    }
    .padding(DS.space.xxs)
    .frame(width: 340)
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
        if model.isRepostReady(n) {
          Label("Ready to repost", systemImage: "checkmark.circle.fill").foregroundStyle(DS.color.success)
        }
      }
      .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      Spacer()
      if selected { DSBadge("Editing", style: .soft(.neutral), size: .sm, help: "The version you're editing") }
      // A button around the switch: one click target, and the row's own tap (select the version) never sees it.
      Button { model.setRepostReady(n, !model.isRepostReady(n)) } label: {
        DSSwitch(isOn: .constant(model.isRepostReady(n)), disabled: model.repostReadyOff != nil, small: true).allowsHitTesting(false)
      }
      .buttonStyle(.plain)
      .disabled(model.repostReadyOff != nil)
      .accessibilityLabel("Ready to repost v\(n)")
      .accessibilityValue(model.isRepostReady(n) ? "On" : "Off")
        .dsTooltip(model.repostReadyOff == nil
                   ? (model.isRepostReady(n) ? "v\(n) is ready to repost: turn off to leave it out of the repost cycle"
                                             : "Mark v\(n) ready to repost (nothing is queued or scheduled)")
                   : nil,
                   disabledReason: model.repostReadyOff)
        .background(ScriptAnchor("Repost ready v\(n)"))
      Menu {
        Button("Duplicate as a separate version") { model.newVersion(copying: n) }
        if n > 1 { Button("Delete v\(n)…", role: .destructive) { requestDelete(n) } }
      } label: { Image(systemName: "ellipsis").foregroundStyle(DS.color.textSecondary) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .dsTooltip("More actions for v\(n)")
    }
    .padding(.horizontal, DS.space.sm).frame(minHeight: 40).padding(.vertical, model.isRepostReady(n) ? 3 : 0)
    .background(selected ? DS.color.selected : .clear, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { model.selectVersion(n) }
    .dsTooltip(selected ? nil : "Edit v\(n)'s text and caption")
  }
}

/// Round 20: "Ready to repost" for the version being edited (shown once a clip has a second version, or this one is
/// marked). The same switch sits on every row of the version list.
struct EditorRepostReadyRow: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let n = model.versionNo
    // The whole row is one button (label, description and switch), like a settings row.
    Button { model.setRepostReady(n, !model.isRepostReady(n)) } label: {
      DSToggle("Ready to repost", description: model.isRepostReady(n)
                 ? "v\(n) is in the repost cycle. Nothing is queued or scheduled by this."
                 : "Turn on when v\(n) is finished, to include it in the repost cycle.",
               isOn: .constant(model.isRepostReady(n)), disabledReason: model.repostReadyOff, size: .sm)
        .allowsHitTesting(false)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.repostReadyOff != nil)
    .accessibilityLabel("Ready to repost v\(n)")
    .accessibilityValue(model.isRepostReady(n) ? "On" : "Off")
      .background(ScriptAnchor("Repost ready"))
      .dsTooltip(model.repostReadyOff == nil ? "Each version you mark ready joins the repost cycle; the clip's stage doesn't change" : nil)
      .padding(.horizontal, DS.space.md).padding(.vertical, DS.space.sm)
  }
}
