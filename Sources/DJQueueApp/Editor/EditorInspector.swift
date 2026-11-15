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
      GeometryReader { viewport in
        ScrollViewReader { proxy in
          ScrollView {
            // Full-width hairlines between sections (the Framer / Webflow / Figma inspector pattern) so each section
            // reads as its own block.
            VStack(alignment: .leading, spacing: 0) {
              // Round 37: one control for reposts, how many times this version posts (short-form only; long-form is
              // never reposted). The whole clip: Mark repostable on the Queue, Edit, Library or Calendar.
              if model.video?.type == .short {
                EditorPostCountRow(model: model)
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
            // Round 28: a press on the column's background (beside, between and below the sections, not on a control)
            // lets go of the selected text, a trim handle and a field's cursor (`EditorClickAway`). Below a short
            // column the background still reaches the bottom, so that space counts as empty too.
            .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .topLeading)
            .background(EditorEmptyBackdrop())
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
      Text("Each version is its own copy: editing one never changes another. Versions post in this order (the arrows change it). Posts is how many times each one goes out.")
        .font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.space.sm).padding(.bottom, DS.space.xs)
      // Round 35: listed in the order they post (1st, 2nd, …); the arrows change it.
      ForEach(model.orderedVersionNumbers, id: \.self) { n in row(n) }
      DSSeparator().padding(.vertical, DS.space.xxs)
      DSButton("New version from v\(model.versionNo)", icon: "plus", variant: .ghost, size: .sm,
               disabledReason: model.readOnly ? "Editing is off for this clip" : nil,
               tooltip: "Copy v\(model.versionNo) as a new version. From then on, editing one never changes the other.") { model.newVersion(copying: nil) }
        .padding(.horizontal, DS.space.xxs).padding(.bottom, DS.space.xs)
    }
    .padding(DS.space.xxs)
    .frame(width: 380)
    .background(DS.color.surfaceRaised)
  }

  private func row(_ n: Int) -> some View {
    let u = model.usage(of: n)
    let selected = n == model.versionNo
    let pos = model.orderPosition(n), count = model.orderedVersionNumbers.count
    return HStack(spacing: DS.space.xs) {
      if count > 1 { orderArrows(n, pos: pos, count: count) }
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text("v\(n)").font(DS.type.calloutSemibold).foregroundStyle(DS.color.text)
          if count > 1 {
            DSBadge(VersionOrder.ordinal(pos), style: pos == 1 ? .soft(.info) : .outline, size: .sm,
                    help: pos == 1 ? "v\(n) posts first" : "v\(n) posts \(VersionOrder.ordinal(pos)) of \(count) versions")
              .background(ScriptAnchor("Version order v\(n)"))
          }
        }
        // Round 35: when it posts, in one line (no platform list).
        Text(model.planLine(of: n)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          .background(ScriptAnchor("Version plan v\(n)"))
        // Round 37: the one repost control, how many times this version posts.
        if model.video?.type == .short { postsStepper(n) }
        if !u.posted.isEmpty { Text("Posted on " + u.posted.map(\.displayName).joined(separator: ", ")) }
      }
      .font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      Spacer()
      if selected { DSBadge("Editing", style: .soft(.neutral), size: .sm, help: "The version you're editing") }
      Menu {
        if count > 1 && pos > 1 && model.versionOrderOff == nil { Button("Post v\(n) first") { model.moveVersion(n, first: true) } }
        Button("Duplicate as a separate version") { model.newVersion(copying: n) }
        if n > 1 { Button("Delete v\(n)…", role: .destructive) { requestDelete(n) } }
      } label: { Image(systemName: "ellipsis").foregroundStyle(DS.color.textSecondary) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .dsTooltip("More actions for v\(n)")
    }
    .padding(.horizontal, DS.space.sm).frame(minHeight: 48).padding(.vertical, 3)
    .background(selected ? DS.color.selected : .clear, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture { model.selectVersion(n) }
    .dsTooltip(selected ? nil : "Edit v\(n)'s text and caption")
  }
}

extension EditorVersionList {
  /// Round 36: "Posts [−] 2 times [+]" on each version, with Default once it has a count of its own. A button style so
  /// the row's own tap (select the version) never sees the clicks.
  fileprivate func postsStepper(_ n: Int) -> some View {
    let own = model.ownPostCount(n)
    return HStack(spacing: DS.space.xs) {
      Text("Posts").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      DSXStepper(label: "Posts of v\(n)", int: Binding(get: { model.postCount(n) }, set: { model.setPostCount(n, $0) }),
                 range: 0...PostUnits.maxCount, less: "Post v\(n) fewer times", more: "Post v\(n) more times",
                 format: EditorPostCountRow.times)
        .disabled(model.postCountOff != nil)
        .background(ScriptAnchor("Version posts v\(n)"))
      if own != nil, model.postCountOff == nil {
        // The same reset icon as a field's Custom chip, so the row stays narrow.
        DSIconButton("arrow.uturn.backward", tooltip: "Back to the clip's Repost: \(EditorPostCountRow.times(model.defaultPostCount(n)).lowercased())",
                     size: .sm) { model.setPostCount(n, nil) }
          .background(ScriptAnchor("Version posts default v\(n)"))
      }
    }
    .padding(.top, 2)
    .dsTooltip(model.postCountOff ?? (own == nil ? "v\(n) follows the clip's Repost: \(EditorPostCountRow.times(model.defaultPostCount(n)).lowercased()). Change it to override"
                                                 : "v\(n)'s own count: it overrides the clip's Repost"))
  }

  /// Round 35: move a version earlier or later in the posting order (Eric: "easily change that priority").
  fileprivate func orderArrows(_ n: Int, pos: Int, count: Int) -> some View {
    let off = model.versionOrderOff
    return VStack(spacing: 0) {
      DSIconButton("chevron.up", tooltip: "Post v\(n) earlier", size: .sm,
                   disabledReason: off ?? (pos == 1 ? "v\(n) already posts first" : nil)) { model.moveVersion(n, by: -1) }
        .background(ScriptAnchor("Version earlier v\(n)"))
      DSIconButton("chevron.down", tooltip: "Post v\(n) later", size: .sm,
                   disabledReason: off ?? (pos == count ? "v\(n) already posts last" : nil)) { model.moveVersion(n, by: 1) }
        .background(ScriptAnchor("Version later v\(n)"))
    }
    .frame(width: 24)
  }
}

/// Round 31: how many times the version being edited posts on each platform. One compact row: the count with − and +,
/// what it means underneath, and "Use default" once the version has a count of its own. Only the count is written
/// (`Store.setPostCount`): no preview or render changes.
struct EditorPostCountRow: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let n = model.versionNo
    let own = model.ownPostCount(n)
    let fallback = model.defaultPostCount(n)
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: DS.space.sm) {
        Text("Posts").font(DS.type.body).foregroundStyle(model.postCountOff == nil ? DS.color.text : DS.color.textDisabled)
        Spacer(minLength: DS.space.xs)
        DSXStepper(label: "Posts of v\(n)", int: Binding(get: { model.postCount(n) }, set: { model.setPostCount(n, $0) }),
                   range: 0...PostUnits.maxCount, less: "Post v\(n) fewer times", more: "Post v\(n) more times",
                   format: Self.times)
          .disabled(model.postCountOff != nil)
          .background(ScriptAnchor("Post count"))
        if own != nil, model.postCountOff == nil {
          DSIconButton("arrow.uturn.backward", tooltip: "Back to \(Self.times(fallback).lowercased())", size: .sm) { model.setPostCount(n, nil) }
            .background(ScriptAnchor("Post count default"))
        }
      }
      Text(model.postCountOff ?? Self.note(n, own: own, fallback: fallback, repost: model.repostOn))
        .font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, DS.space.md).padding(.vertical, DS.space.sm)
    .dsTooltip(model.postCountOff == nil ? "How many times v\(n) goes out on each platform. Repeats are spaced out" : nil)
  }

  static func times(_ n: Int) -> String { n == 0 ? "Never" : n == 1 ? "Once" : "\(n) times" }

  /// One short line under the stepper.
  static func note(_ n: Int, own: Int?, fallback: Int, repost: Bool = true) -> String {
    if own == 0 { return "v\(n) doesn't post." }
    if own != nil { return "Set for v\(n). Without it: \(times(fallback).lowercased())." }
    if fallback == 0 { return "v\(n) doesn't post (it went out before reposts were counted)." }
    return repost ? "The clip is repostable: \(times(fallback).lowercased()) on each platform." : "On each platform."
  }
}

