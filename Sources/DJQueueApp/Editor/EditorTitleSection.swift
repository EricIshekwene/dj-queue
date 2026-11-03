import DJQCore
import SwiftUI

/// Title (#2/#3 revised): the clip's Title from metadata — suggestion chips (upstream `title_suggestions`, never
/// generated here), the raw marker tag, a free text field and "Ask an agent". The overlay text, caption {text},
/// YouTube title and display name follow the Title mechanically.
struct EditorTitleSection: View {
  @ObservedObject var model: EditorModel
  @State private var editing = false
  @FocusState private var focused: Bool

  var body: some View {
    EditorSectionView(.title) {
      VStack(alignment: .leading, spacing: DS.space.sm) {
        current
        if model.needsTitleHelp { agentCallout }
        suggestionsBlock
        field
        HStack(spacing: DS.space.xs) {
          DSButton("Use raw tag", icon: "tag", variant: .outline, size: .sm,
                   disabledReason: model.title == model.rawTag ? "The Title already is the raw tag" : nil,
                   tooltip: "Set the Title to “\(model.rawTag)” as typed") {
            model.setTitle(model.rawTag, source: "app")
          }
          if !model.needsTitleHelp {
            DSButton("Ask an agent", icon: "doc.on.clipboard", variant: .ghost, size: .sm,
                     tooltip: "Copy a song-name prompt for your agent") {
              model.copyAgentPrompt()
            }
          }
          Spacer(minLength: 0)
        }
        kindRow
      }
    }
    .onChange(of: model.focusTitle) { _, _ in focused = true }
  }

  // MARK: Current title

  @ViewBuilder private var current: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if let t = model.title {
          Text(t).font(DS.type.headline).foregroundStyle(DS.color.text).lineLimit(2)
        } else {
          Text(model.rawTag).font(DS.type.headline).foregroundStyle(DS.color.textSecondary).lineLimit(2)
          DSBadge("Raw tag", style: .outline, size: .sm).dsTooltip("No Title yet; screens show the marker tag")
        }
        Spacer(minLength: 0)
        EditorCustomTag(isCustom: model.title != nil, resetHelp: "Clear the Title (screens show the raw tag)",
                        customHelp: "Typed or chosen by you (not the raw tag)") {
          model.titleDraft = nil
          model.setTitle(nil)
        }
      }
      if let t = model.title, t != model.rawTag {
        Text("Raw tag: \(model.rawTag)").font(DS.type.caption).foregroundStyle(DS.color.textTertiary).lineLimit(1)
      }
    }
  }

  // MARK: Ask an agent (prominent when the metadata has no confident title)

  private var agentCallout: some View {
    VStack(alignment: .leading, spacing: DS.space.xs) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "questionmark.bubble").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.color.warning)
        Text(model.suggestions.isEmpty ? "No title in the metadata yet" : "The metadata isn't sure about this title")
          .font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
      }
      Text("Copy a ready-made prompt for your agent. It finds the song names and sends suggestions back with djq; they show up here as chips.")
        .font(DS.type.caption).foregroundStyle(DS.color.textSecondary).fixedSize(horizontal: false, vertical: true)
      DSButton("Ask an agent", icon: "doc.on.clipboard", variant: .secondary, size: .sm,
               tooltip: "Copy a song-name prompt for your agent") { model.copyAgentPrompt() }
    }
    .padding(DS.space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DS.color.warningTint, in: RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous))
  }

  // MARK: Suggestions

  @ViewBuilder private var suggestionsBlock: some View {
    if model.suggestions.isEmpty {
      EditorHint("No title suggestions yet", icon: "text.badge.plus")
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Text("Title suggestions").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
        DSFlowLayout(spacing: 6) {
          ForEach(model.suggestions) { s in suggestionChip(s) }
        }
      }
    }
  }

  private func suggestionChip(_ s: TitleSuggestion) -> some View {
    let chosen = model.title == s.text
    return EditorSuggestionChip(text: s.text, detail: Self.detail(s), chosen: chosen, tooltip: tooltip(s, chosen: chosen)) {
      model.accept(s)
    }
  }

  /// The chip truncates in the 340 pt column, so its tooltip leads with the full title (the bubble shows 3 lines;
  /// matched tracks follow when there's room).
  private func tooltip(_ s: TitleSuggestion, chosen: Bool) -> String {
    var t = "“\(s.text)” · " + (chosen ? "the Title" : "click to use as the Title")
    if let d = Self.detail(s) { t += "\n" + d }
    return t
  }

  /// "Yayo – Kabza De Small · 82 %" — matched tracks and confidence, as subtle text.
  static func detail(_ s: TitleSuggestion) -> String? {
    var parts: [String] = []
    let tracks = s.tracks.map { t in t.artist.map { "\(t.title) – \($0)" } ?? t.title }
    if !tracks.isEmpty { parts.append(tracks.joined(separator: ", ")) }
    if let c = s.confidence { parts.append("\(Int((c * 100).rounded())) %") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // MARK: Free text

  private var field: some View {
    HStack(spacing: DS.space.xs) {
      TextField(model.title == nil ? "Type a title" : "Title", text: draftBinding)
        .textFieldStyle(.plain)
        .font(DS.type.body)
        .focused($focused)
        .onSubmit(commit)
        .padding(.horizontal, 12).frame(height: DS.size.controlMd)
        .modifier(DSFieldBox(focused: focused, hovering: false, error: false, disabled: false))
        .dsTooltip("Rename: text, caption and YouTube title follow", shortcut: "↩")
      if draftDiffers {
        DSButton("Set", variant: .outline, size: .md, tooltip: "Save this Title", shortcut: "↩", action: commit)
      }
    }
    .onChange(of: focused) { _, f in if !f { model.commitTitleDraft() } }
  }

  /// The draft lives on the model so ⌘] / Done (which don't blur the field) still save it.
  private var draftBinding: Binding<String> {
    Binding(get: { model.titleDraft ?? model.title ?? "" }, set: { model.titleDraft = $0 })
  }

  private var draftDiffers: Bool {
    guard let d = model.titleDraft else { return false }
    return d.trimmingCharacters(in: .whitespacesAndNewlines) != (model.title ?? "")
  }

  private func commit() { model.commitTitleDraft() }

  // MARK: Kind

  private var kindRow: some View {
    HStack {
      Text("Kind").font(DS.type.calloutMedium).foregroundStyle(DS.color.textSecondary)
      Spacer()
      DSSegmented(selection: Binding(get: { model.video?.kind ?? .djVid }, set: { model.setKind($0) }),
                  segments: Kind.allCases.map { DSSegment(value: $0, title: $0.displayName) }, size: .sm)
        .dsTooltip("Set the kind; Talking clips start with no text")
    }
    .padding(.top, DS.space.xxs)
  }
}

/// One suggestion chip (Title or Text on the video): the text, an optional subtle detail line (tracks, confidence),
/// a check when it's the current value. Long text wraps inside the column, then truncates; the tooltip has it all.
struct EditorSuggestionChip: View {
  let text: String
  var detail: String?
  var chosen: Bool
  var lineLimit = 2
  var tooltip: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 1) {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          if chosen { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)) }
          Text(text).font(DS.type.captionMedium).lineLimit(lineLimit).multilineTextAlignment(.leading)
        }
        .foregroundStyle(DS.color.text)
        if let d = detail {
          Text(d).font(.system(size: 10.5)).foregroundStyle(DS.color.textTertiary).lineLimit(2)
        }
      }
      .padding(.horizontal, 11).padding(.vertical, 5)
      .background(chosen ? DS.color.selected : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(chosen ? DS.color.text.opacity(0.35) : DS.color.borderStrong))
      .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(EditorPressStyle())
    .dsTooltip(tooltip)
  }
}

/// Plain button that dims slightly while pressed.
struct EditorPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
  }
}
