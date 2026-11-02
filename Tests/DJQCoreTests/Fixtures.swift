import Foundation
@testable import DJQCore

/// A throwaway "DJ Video" folder with one session and fake clip files.
final class Fixture {
  let dir: URL
  let paths: Paths
  let clock: FixedClock
  let store: Store
  let sessionDir: URL

  /// 2026-11-03 09:00 New York (a Monday).
  static let monday9am: Date = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
  }()

  init(clips: [(tag: String, duration: Double)] = Fixture.defaultClips, longform: Bool = true,
       sessionName: String = "2026-10-23 – Afroween Jazz Piano") throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-test-\(UUID().uuidString)")
    let root = dir.appendingPathComponent("DJ Video")
    paths = Paths(root: root, appSupport: dir.appendingPathComponent("support"), logs: dir.appendingPathComponent("logs"),
                  launchAgents: dir.appendingPathComponent("LaunchAgents"))
    sessionDir = paths.sessions.appendingPathComponent(sessionName)
    let fm = FileManager.default
    for sub in ["Clips", "Ready to Post/Longform", "Ready to Post/Shortform", "Posted/Longform", "Posted/Shortform", "Video"] {
      try fm.createDirectory(at: sessionDir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try fm.createDirectory(at: paths.sessions.appendingPathComponent("_Template – copy me"), withIntermediateDirectories: true)
    clock = FixedClock(Fixture.monday9am)
    store = try Store(memoryWith: paths, clock: clock)
    try writeManifest(clips: clips, longform: longform, sessionName: sessionName)
  }

  static let defaultClips: [(tag: String, duration: Double)] = [
    ("yayo x johnny", 27.1), ("poosh 5", 158.0), ("bone shaker", 15.2), ("asabone x forgiveness", 28.8),
  ]

  var entries: [[String: Any]] = []

  func writeManifest(clips: [(tag: String, duration: Double)], longform: Bool, sessionName: String) throws {
    entries = []
    if longform {
      let f = "Ready to Post/Longform/\(sessionName) – Part 1 (longform).mp4"
      try fakeFile(f, seed: "long")
      entries.append(["id": "long-0001", "name": "\(sessionName) – Part 1", "tags": ["Afroween"], "type": "long-form",
                      "content-type": "dj vid", "file": f, "session": sessionName, "part": 1, "start": 0.0,
                      "end": 1788.79, "duration": 1788.79, "audio": "rekordbox", "status": "ready to post"])
    }
    for (i, c) in clips.enumerated() {
      let f = "Clips/\(sessionName) – \(c.tag).mp4"
      try fakeFile(f, seed: c.tag)
      let start = Double(100 * i)
      entries.append(["id": "clip-\(i)", "name": "\(sessionName) – \(c.tag)", "tags": [c.tag], "type": "short-form",
                      "content-type": "dj vid", "file": f, "session": sessionName, "part": i < 2 ? 1 : 2,
                      "marked_start": start + 3, "marked_end": start + c.duration - 3, "start": start,
                      "end": start + c.duration, "duration": c.duration, "grace": 3.0,
                      "audio": i < 2 ? "rekordbox" : "camera", "markers": [c.tag], "status": "exported"])
    }
    try saveManifest()
  }

  func saveManifest() throws {
    let data = try JSONSerialization.data(withJSONObject: ["session": sessionDir.lastPathComponent, "videos": entries],
                                          options: [.prettyPrinted])
    try data.write(to: sessionDir.appendingPathComponent("videos.json"))
  }

  func fakeFile(_ rel: String, seed: String) throws {
    var d = Data("FAKE-MP4-\(seed)-".utf8)
    d.append(Data(repeating: UInt8(seed.count % 251), count: 2048))
    try d.write(to: sessionDir.appendingPathComponent(rel))
  }

  @discardableResult
  func intake() throws -> IntakeReport { try Intake(store: store).run() }

  deinit { try? FileManager.default.removeItem(at: dir) }
}
