import AppKit
import DJQCore
import SwiftUI
import UniformTypeIdentifiers

/// Round 21 (P1): photos dropped on the Edit page become photo posts, through the same `model.takePhotos` the file
/// picker ends in. One photo is added at once; several open the import sheet. Files that aren't photos are refused in
/// a toast, in `PhotoImport.refusal`'s words. While a drag is over the page it shows a quiet outline.
///
/// A drag carries files (Finder) or pictures with no file behind them (Photos, a browser). A picture is written to a
/// temporary folder first and taken from there, so both kinds end up as files for the importer. A drag with neither
/// (text, a link) isn't accepted at all: the pointer shows it can't be dropped and nothing is highlighted.
struct PhotoDrop: ViewModifier {
  @Bindable var model: AppModel
  @State private var targeted = false
  private var ui: PhotoImportUI { .shared }

  func body(content: Content) -> some View {
    content
      .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $targeted) { providers in
        Self.files(from: providers) { urls in
          if urls.isEmpty {
            model.show("That drag has no photo DJ Queue can read. Drop photo files (JPEG, PNG, HEIC, WebP or TIFF)", error: true)
          } else {
            model.takePhotos(urls)
          }
        }
        return true
      }
      .overlay {
        if targeted || ui.dropTargeted {
          ZStack {
            RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous)
              .strokeBorder(DS.color.borderStrong, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
            HStack(spacing: 8) {
              Image(systemName: "photo.badge.plus").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.color.textSecondary)
              Text("Drop photos to add them to Edit").font(DS.type.calloutMedium).foregroundStyle(DS.color.text)
            }
            .padding(.horizontal, DS.space.md)
            .frame(height: DS.size.bulkBar)
            .dsFloatingSurface(radius: DS.size.bulkBar / 2)
          }
          .padding(DS.space.sm)
          .allowsHitTesting(false)
          .transition(.opacity)
        }
      }
      .dsAnimation(DS.motion.fade, value: targeted)
  }

  /// The dropped items as files, in the order dragged, handed over on the main thread.
  static func files(from providers: [NSItemProvider], then: @escaping @MainActor ([URL]) -> Void) {
    let box = Found(count: providers.count)
    let group = DispatchGroup()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("djq-dropped-\(UUID().uuidString)")
    for (i, p) in providers.enumerated() {
      group.enter()
      if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = p.loadObject(ofClass: URL.self) { url, _ in
          if let url, url.isFileURL { box.set(i, url) }
          group.leave()
        }
      } else {
        // A picture with no file of its own. The system's copy goes away when this closure returns, so keep one.
        let name = p.suggestedName
        _ = p.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
          defer { group.leave() }
          guard let url else { return }
          let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
          let base = (name?.isEmpty == false ? name! : "Dropped photo \(i + 1)").replacingOccurrences(of: "/", with: "-")
          let file = base.lowercased().hasSuffix("." + ext.lowercased()) ? base : "\(base).\(ext)"
          let dest = folder.appendingPathComponent("\(i + 1)").appendingPathComponent(file)
          do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
            box.set(i, dest)
          } catch {
            Log.shared.error("dropped photo not kept: \(error)")
          }
        }
      }
    }
    group.notify(queue: .main) {
      let urls = box.all()
      MainActor.assumeIsolated { then(urls) }
    }
  }

  /// The loaded files by position (the loads come back on other threads, in any order).
  private final class Found: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?]
    init(count: Int) { urls = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ url: URL) { lock.lock(); urls[i] = url; lock.unlock() }
    func all() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls.compactMap { $0 } }
  }
}

extension View {
  /// Takes photos dropped on this page as new photo posts.
  func photoDrop(_ model: AppModel) -> some View { modifier(PhotoDrop(model: model)) }
}
