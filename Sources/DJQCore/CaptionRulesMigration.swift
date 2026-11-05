import Foundation

/// Schema 7 (v0.8.3): `{title}` and `{link}` are tokens, and each tag appears once where a clip's tags are filled in. A clip with
/// scheduled or posted posts that would read differently keeps its old caption as that platform's own, in one journaled batch
/// (`djq bulk undo` restores it), and nothing else changes.
enum CaptionRulesMigration {
  static let action = "caption-rules-migration"

  @discardableResult
  static func run(_ store: Store) throws -> [String] {
    let now = try CaptionHold.Sources(store)
    let held = try HashtagGroupsMigration.clipsWithPosts(store).sorted().compactMap { try store.video(id: $0) }
      .filter { try CaptionHold.outputs($0, now, store: store, legacy: true) != CaptionHold.outputs($0, now, store: store) }
    try store.db.transaction {
      try BulkActions(store: store).record(action, ids: held.map(\.id), revalidate: false) {
        let saved = try held.map { ($0, try CaptionHold.outputs($0, now, store: store, legacy: true)) }
        for (v, outputs) in saved { try CaptionHold.keep(v, as: outputs, store: store) }
      }
      try store.db.exec("PRAGMA user_version = 7")
    }
    return held.map(\.id)
  }
}
