import DJQCore
import SwiftUI

/// Round 21: the photo import sheet, shown by `MainWindowView` while `model.photoImportRequest` is set. STUB from the
/// session parent; its owner replaces the body.
struct PhotoImportSheet: View {
  @Bindable var model: AppModel
  let request: PhotoImportRequest

  var body: some View {
    DSDialog("Add photos", onClose: { model.photoImportRequest = nil }) {
      Text("Not built yet").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
    } footer: {
      DSButton("Cancel", variant: .ghost) { model.photoImportRequest = nil }
    }
  }
}
