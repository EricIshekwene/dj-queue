import DJQCore
import SwiftUI

/// Round 21 (P1): image files dropped on the Edit page become photo posts, through the same `model.takePhotos` the
/// file picker ends in. One photo is added at once; several open the import sheet. Files that aren't photos are
/// refused in a toast, in `PhotoImport.refusal`'s words. While a drag is over the page it shows a quiet outline.
struct PhotoDrop: ViewModifier {
  @Bindable var model: AppModel
  @State private var targeted = false
  private var ui: PhotoImportUI { .shared }

  func body(content: Content) -> some View {
    content
      .dropDestination(for: URL.self) { urls, _ in
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        model.takePhotos(files)
        return true
      } isTargeted: { targeted = $0 }
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
}

extension View {
  /// Takes image files dropped on this page as new photo posts.
  func photoDrop(_ model: AppModel) -> some View { modifier(PhotoDrop(model: model)) }
}
