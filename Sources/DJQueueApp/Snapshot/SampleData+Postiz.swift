import DJQCore
import Foundation

/// Round 6 sample (throwaway snapshot DB only): Postiz connected with six sample channels (Threads' disabled), every
/// platform but Facebook set to Postiz.
extension SampleData {
  static func seedPostiz(store: Store, clock: FixedClock, now: Date) throws {
    clock.set(now)
    var st = try store.settings()
    for p in Platform.allCases {
      st.publishing.publishers[p] = p == .facebook ? .manual : .postiz
      st.publishing.channels[p] = PostizSamples.channels.first { $0.platform == p }?.id
    }
    try store.save(st)
    struct Cache: Encodable { var fetchedAt: Date; var integrations: [PostizIntegration] }
    try store.setKV(PostizChannelCache.kvKey, Cache(fetchedAt: now.addingTimeInterval(-25 * 60), integrations: PostizSamples.channels))
  }
}
