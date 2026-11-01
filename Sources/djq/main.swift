import DJQCore
import Foundation
// Placeholder until the ENGINE agent writes the real CLI: runs intake and prints a summary.
let store = try Store(paths: .standard)
let r = try Intake(store: store).run()
let vids = try store.videos()
print("sessions \(r.sessionsSeen) new \(r.newVideos.count) missing \(r.missing.count) relinked \(r.relinked.count) untracked \(r.untracked.count) parseErrors \(r.parseErrors.count) dup \(r.duplicateIds.count)")
print("short \(vids.filter { $0.type == .short }.count) long \(vids.filter { $0.type == .long }.count)")
for v in vids.sorted(by: { ($0.part ?? 0, $0.start ?? 0) < ($1.part ?? 0, $1.start ?? 0) }).prefix(70) {
  print(v.type == .long ? "LONG" : "    ", v.state.rawValue, String(format: "%6.1f", v.duration), v.audio ?? "-", "|", v.tag, "→", Prefill.text(tag: v.tag, kind: .djVid, rules: PrefillRules()).replacingOccurrences(of: "\n", with: " / "))
}
