import DJQCore
import SwiftUI

/// Round 21: the "Post at a set time" dialog, shown by `MainWindowView` while `model.postAtRequest` is set (over the
/// editor too). STUB from the session parent; its owner replaces the body.
struct PostAtDialog: View {
  @Bindable var model: AppModel
  let request: PostAtRequest

  var body: some View {
    DSDialog("Post at a set time", onClose: { model.postAtRequest = nil }) {
      Text("Not built yet").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
    } footer: {
      DSButton("Cancel", variant: .ghost) { model.postAtRequest = nil }
    }
  }
}
