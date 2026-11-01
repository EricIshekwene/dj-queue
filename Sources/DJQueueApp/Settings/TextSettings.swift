import DJQCore
import SwiftUI

/// S.S6: default text style/size/position, caption templates, hashtag sets by primary category, prefill rules.
struct TextSettings: View {
  @Bindable var model: AppModel
  @State private var templates: [CaptionTemplate] = []
  @State private var sets: [HashtagSet] = []
  @State private var sampleTag = "yayo x johnny"
  @State private var rules = PrefillRules()
  @State private var newCategory = ""

  var body: some View {
    Form {
      Section("Overlay text defaults") {
        SettingRow(title: "Style") {
          HStack(spacing: 8) {
            ForEach(TextStyle.allCases, id: \.self) { s in StyleTile(style: s, selected: model.settings.defaultStyle == s) { model.update { $0.defaultStyle = s } } }
          }
        }
        SettingRow(title: "Size", subtitle: "Points at 1080 wide") {
          HStack {
            Picker("", selection: model.binding(\.defaultTextSize)) {
              Text("S").tag(52.0)
              Text("M").tag(64.0)
              Text("L").tag(80.0)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Text("\(Int(model.settings.defaultTextSize)) pt").font(DS.Font.mono).foregroundStyle(.secondary)
          }
        }
        SettingRow(title: "Position", subtitle: "Draggable per video in the editor") {
          Picker("", selection: model.binding(\.defaultPosY)) {
            Text("Top").tag(0.18)
            Text("Upper").tag(0.32)
            Text("Centre").tag(0.5)
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
      }

      Section {
        ForEach($templates) { $t in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              TextField("Name", text: $t.name).textFieldStyle(.plain).font(DS.Font.bodyStrong).labelsHidden()
              Spacer()
              if model.settings.defaultCaptionTemplateId == t.id {
                StatusPill(text: "Default", tint: .accentColor)
              } else {
                Button("Make default") { model.update { $0.defaultCaptionTemplateId = t.id } }.buttonStyle(.link).font(DS.Font.secondary)
              }
              Button { delete(t) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                .disabled(model.settings.defaultCaptionTemplateId == t.id)
            }
            TextField("Template", text: $t.template, axis: .vertical)
              .font(DS.Font.mono).lineLimit(2...5).textFieldStyle(.roundedBorder).labelsHidden()
              .multilineTextAlignment(.leading)
            Text(preview(t)).font(DS.Font.secondary).foregroundStyle(.secondary).lineLimit(4)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(6).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
          }
          .padding(.vertical, 4)
          .onChange(of: t) { _, nt in save(nt) }
        }
        Button("Add template", systemImage: "plus") {
          let t = CaptionTemplate(id: newId(), name: "New template", template: "{text}\n\n{hashtags}", sort: (templates.map(\.sort).max() ?? 0) + 1)
          save(t)
          templates.append(t)
        }
      } header: {
        Text("Caption templates")
      } footer: {
        Text("Variables: {text} overlay text on one line · {tag} marker tag · {set} session name · {hashtags}").font(DS.Font.secondary)
      }

      ForEach(categories, id: \.self) { cat in
        Section {
          ForEach($sets) { $s in
            if s.category == cat {
              HStack(alignment: .firstTextBaseline) {
                TextField("Name", text: $s.name).textFieldStyle(.plain).font(DS.Font.bodyStrong).frame(width: 170).labelsHidden()
                TextField("#tags", text: Binding(get: { s.tags.joined(separator: " ") },
                                                 set: { s.tags = $0.split(separator: " ").map(String.init) }))
                  .textFieldStyle(.roundedBorder).font(DS.Font.mono).labelsHidden().multilineTextAlignment(.leading)
                Toggle("Default", isOn: Binding(get: { model.settings.defaultHashtagSetIds.contains(s.id) }, set: { on in
                  let id = s.id
                  model.update { st in
                    if on { if !st.defaultHashtagSetIds.contains(id) { st.defaultHashtagSetIds.append(id) } } else { st.defaultHashtagSetIds.removeAll { $0 == id } }
                  }
                }))
                .toggleStyle(.checkbox)
                Button { deleteSet(s) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
              }
              .onChange(of: s) { _, ns in try? model.store.save(ns) }
            }
          }
          Button("Add set under \(cat)", systemImage: "plus") { addSet(cat) }.buttonStyle(.link)
        } header: {
          Text("Hashtags · \(cat)")
        }
      }
      Section {
        HStack {
          TextField("New primary category", text: $newCategory).textFieldStyle(.roundedBorder).frame(width: 220)
          Button("Add category") {
            guard !newCategory.isEmpty else { return }
            addSet(newCategory)
            newCategory = ""
          }
          .disabled(newCategory.isEmpty)
        }
      } footer: {
        Text("Each video gets its hashtags from its chosen sets; defaults apply to new videos.").font(DS.Font.secondary)
      }

      Section {
        SettingRow(title: "Rules file", subtitle: model.store.paths.prefillRules.path) {
          HStack {
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([model.store.paths.prefillRules]) }
            Button("Open") { NSWorkspace.shared.open(model.store.paths.prefillRules) }
          }
        }
        SettingRow(title: "Joiner") {
          TextField("", text: $rules.joiner).textFieldStyle(.roundedBorder).frame(width: 60)
        }
        SettingRow(title: "One line up to", subtitle: "Per name / whole line, characters") {
          HStack {
            Stepper("\(rules.maxShortName)", value: $rules.maxShortName, in: 6...30).fixedSize()
            Stepper("\(rules.maxOneLine)", value: $rules.maxOneLine, in: 10...50).fixedSize()
          }
        }
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Live preview").font(DS.Font.bodyStrong)
            TextField("Marker tag", text: $sampleTag).textFieldStyle(.roundedBorder).labelsHidden()
          }
          Text(Prefill.text(tag: sampleTag, kind: .djVid, rules: rules).isEmpty ? " " : Prefill.text(tag: sampleTag, kind: .djVid, rules: rules))
            .font(.system(size: 15, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.black)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            .frame(maxWidth: .infinity)
          Text("CLI: djq prefill \"\(sampleTag)\"").font(DS.Font.mono).foregroundStyle(.secondary)
        }
      } header: {
        Text("Prefill from tag")
      } footer: {
        Text("Uses “x”, never an arrow; no emoji unless set in the file. Talking videos get no prefill.").font(DS.Font.secondary)
      }
    }
    .onAppear(perform: load)
    .onChange(of: rules) { _, r in r.write(model.store.paths) }
  }

  private var categories: [String] {
    var seen: [String] = []
    for s in sets where !seen.contains(s.category) { seen.append(s.category) }
    return seen
  }

  private func load() {
    templates = (try? model.store.captionTemplates()) ?? []
    sets = (try? model.store.hashtagSets()) ?? []
    rules = PrefillRules.load(model.store.paths)
  }

  private func save(_ t: CaptionTemplate) { try? model.store.save(t) }

  private func delete(_ t: CaptionTemplate) {
    model.perform("Template deleted") { try model.store.deleteCaptionTemplate(t.id) }
    templates.removeAll { $0.id == t.id }
  }

  private func addSet(_ cat: String) {
    let s = HashtagSet(id: newId(), name: "\(cat) · new", category: cat, tags: ["#djlovd"], sort: (sets.filter { $0.category == cat }.map(\.sort).max() ?? -1) + 1)
    try? model.store.save(s)
    sets.append(s)
  }

  private func deleteSet(_ s: HashtagSet) {
    model.perform("Set deleted") { try model.store.deleteHashtagSet(s.id) }
    sets.removeAll { $0.id == s.id }
  }

  private func preview(_ t: CaptionTemplate) -> String {
    let tags = (sets.first { model.settings.defaultHashtagSetIds.contains($0.id) }?.tags ?? ["#djlovd"]).prefix(4)
    return Captions.fill(t.template, text: "Yayo x Johnny", tag: "yayo x johnny", set: "Afroween Jazz Piano", hashtags: Array(tags))
  }
}

/// Each tile is drawn in its own style (E.S5 alt refs).
struct StyleTile: View {
  let style: TextStyle
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        ZStack {
          RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.25))
          sample
        }
        .frame(width: 78, height: 46)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        Text(style.displayName).font(DS.Font.secondary).foregroundStyle(selected ? Color.accentColor : .secondary)
      }
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder private var sample: some View {
    switch style {
    case .box:
      Text("Aa").font(.system(size: 13, weight: .bold)).foregroundStyle(.black).padding(.horizontal, 6).background(Color.white, in: RoundedRectangle(cornerRadius: 3))
    case .outline:
      ZStack {
        ForEach(0..<4, id: \.self) { i in
          Text("Aa").font(.system(size: 15, weight: .heavy)).foregroundStyle(.black)
            .offset(x: i % 2 == 0 ? 1 : -1, y: i < 2 ? 1 : -1)
        }
        Text("Aa").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
      }
    case .shadow:
      Text("Aa").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white).shadow(color: .black.opacity(0.9), radius: 2, y: 1)
    }
  }
}
