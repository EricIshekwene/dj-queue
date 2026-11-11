import DJQCore
import Foundation

/// `djq photo …` (round 21): make photo posts and list them. A photo post lands in Edit; nothing here sends anything
/// to the Queue (that is Eric's Send to Queue, `djq requeue`, on Eric's word only).
enum PhotoCommand {
  static let usage = """
    usage: djq photo <command>

      photo add <file>… [--separate] [--title "<title>"] [--json]
                           one post from every file, in the order given (a carousel when there are several);
                           --separate makes a post per file. JPEG, PNG, HEIC, WebP and TIFF. Each file is copied into
                           DJ Queue's Photos folder; the original is never moved or changed. The post lands in Edit.
      photo list [--json]  every photo post: stage, photos, title

    A photo post needs no score, never posts to YouTube Shorts, and a carousel longer than a platform takes sends its
    first photos there (X 4, Instagram 10, Facebook 10, Threads 20, TikTok 35).
    """

  struct AddOut: Codable {
    var posts: [AgentAPI.VideoSummary]
    var skipped: [PhotoImport.Skipped]
  }

  static func run(_ store: Store, _ wrote: inout Bool) throws -> Int32 {
    let json = flag("--json")
    guard let sub = args.first else { print(usage); return 0 }
    args.removeFirst()
    switch sub {
    case "help", "-h", "--help":
      print(usage)
      return 0
    case "add":
      let title = option("--title")
      let separate = flag("--separate")
      let files = args.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
      guard !files.isEmpty else { throw CLIError("photo add needs at least one file\n\n\(usage)") }
      let r = try PhotoImport(store: store).add(files: files, mode: separate ? .separate : .carousel, title: title, titleSource: "agent")
      wrote = !r.posts.isEmpty
      let out = AddOut(posts: try r.posts.map { try AgentAPI.summary($0, store: store) }, skipped: r.skipped)
      if json {
        try printJSON(out)
      } else {
        for v in r.posts { print("added \(short(v.id))  \(v.photoLabel ?? "Photo")  \(v.displayName)  (in Edit)") }
        for s in r.skipped { print("skipped \(s.file): \(s.reason)") }
        if r.posts.isEmpty { print("no post made") }
      }
      return r.posts.isEmpty ? 1 : 0
    case "list":
      let list = try AgentAPI.videos(store: store).filter { $0.media == "photo" }
      if json { try printJSON(list); return 0 }
      for v in list {
        print("  \(short(v.id))  \(pad(stageLabel(v), 11)) \(pad(v.photos.count == 1 ? "Photo" : "Carousel · \(v.photos.count)", 14))\(v.display_name)"
              + (v.reasons.isEmpty ? "" : "  — " + v.reasons.joined(separator: " · ")))
      }
      print("  \(list.count) photo post(s)")
      return 0
    default:
      throw CLIError("unknown photo command \(sub)\n\n\(usage)")
    }
  }
}
