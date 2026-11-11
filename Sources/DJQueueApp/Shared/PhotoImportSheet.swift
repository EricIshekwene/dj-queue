import DJQCore
import SwiftUI

/// Round 21: the photo import sheet (D3), shown by `MainWindowView` while `model.photoImportRequest` is set. Several
/// picked or dropped photos land here: the photos in order, an optional title, and one choice, a carousel or a post
/// per photo. "Add to Edit" runs `model.importPhotos`; nothing here sends anything to the Queue.
struct PhotoImportSheet: View {
  @Bindable var model: AppModel
  let request: PhotoImportRequest
  @State private var title = ""
  @State private var separate = false
  @State private var thumbs: [URL: NSImage] = [:]

  private var ui: PhotoImportUI { .shared }
  private var mode: PhotoImport.Mode { separate ? .separate : .carousel }

  var body: some View {
    let n = request.files.count
    DSDialog("Add \(n) photos", description: "DJ Queue keeps its own copy. The files you picked stay where they are.",
             icon: "photo.stack", width: 520, onClose: close) {
      VStack(alignment: .leading, spacing: DS.space.md) {
        strip
        DSTextField("Title", placeholder: "Optional", text: $title,
                    hint: separate ? "Every post gets this title. You can change each one in the editor."
                      : "Names the post in every list. You can change it in the editor.",
                    onSubmit: add)
          .background(ScriptAnchor("Import title"))
        DSToggle("A post per photo", description: "Off: all \(n) go out together as one carousel.", isOn: $separate)
          .background(ScriptAnchor("A post per photo"))
        plan(n)
      }
    } footer: {
      DSButton("Cancel", variant: .ghost, shortcut: "esc", action: close).keyboardShortcut(.cancelAction)
      DSButton("Add to Edit", variant: .primary, isLoading: ui.importing,
               tooltip: "Add \(separate ? "\(n) posts" : "the carousel") to Edit. Nothing is sent to the Queue", shortcut: "↩", action: add)
        .keyboardShortcut(.defaultAction)
        .background(ScriptAnchor("Add to Edit"))
    }
    .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e3)
    .task(id: request.files) { await loadThumbs() }
  }

  // MARK: Pieces

  /// The picked photos in posting order, ending in an "add" tile.
  private var strip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: DS.space.xs) {
        ForEach(Array(request.files.enumerated()), id: \.element) { i, url in thumb(i, url) }
        DSIconButton("plus", tooltip: "Pick more photos", variant: .outline, size: .lg) { model.askAddPhotos() }
          .frame(width: Self.tile, height: Self.tile)
      }
      .padding(.vertical, 1)
    }
  }

  private static let tile: CGFloat = 76

  private func thumb(_ i: Int, _ url: URL) -> some View {
    ZStack {
      if let img = thumbs[url] {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
      } else {
        DSPosterPlaceholder(symbol: "photo")
      }
    }
    .frame(width: Self.tile, height: Self.tile)
    .clipShape(RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous).strokeBorder(DS.color.border) }
    .overlay(alignment: .bottomLeading) {
      Text("\(i + 1)").font(DS.type.micro.monospacedDigit()).foregroundStyle(.white)
        .padding(.horizontal, 6).frame(height: 18)
        .background(Color.black.opacity(0.63), in: Capsule())
        .padding(5)
    }
    .background(ScriptAnchor("Import photo \(i + 1)"))
    .dsTooltip(i == 0 && !separate ? "\(url.lastPathComponent) · the first photo is the cover" : url.lastPathComponent)
    .accessibilityLabel("Photo \(i + 1): \(url.lastPathComponent)")
  }

  /// What "Add to Edit" will make, then anything a platform does differently with that many photos.
  private func plan(_ n: Int) -> some View {
    let text = AppModel.importPlan(count: n, mode: mode)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: separate ? "photo" : "photo.stack").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.color.textSecondary)
        Text(text).font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
      }
      .background(ScriptAnchor("Import plan: \(text)"))
      ForEach(model.importNotices(count: n, mode: mode), id: \.self) { note in
        EditorHint(note, icon: "info.circle")
      }
    }
    .padding(DS.space.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dsSurface(DS.color.surfaceSunken, radius: DS.radius.sm, border: nil)
  }

  // MARK: Actions

  private func add() {
    guard !ui.importing else { return }
    model.importPhotos(urls: request.files, mode: mode, title: title)
  }

  private func close() {
    guard !ui.importing else { return }
    model.photoImportRequest = nil
  }

  private func loadThumbs() async {
    for url in request.files where thumbs[url] == nil {
      let img = await Task.detached(priority: .userInitiated) { AppModel.loadImage(url, maxPixel: 320) }.value
      if let img { thumbs[url] = img }
    }
  }
}
