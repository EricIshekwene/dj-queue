import DJQCore
import Foundation

/// `djq photo …` (round 21): make photo posts and list them. A photo post lands in Edit; nothing here sends anything
/// to the Queue (that is Eric's Send to Queue, `djq requeue`, on Eric's word only).
/// Round 23: `--audio` and `photo audio` turn one photo and an audio file into a video (`StillVideo`).
enum PhotoCommand {
  /// The command word (`djq photo …`).
  static let name = "photo"

  static let usage = """
    usage: djq photo <command>

      photo add <file>… [--separate] [--title "<title>"] [--json]
                           one post from every file, in the order given (a carousel when there are several);
                           --separate makes a post per file. JPEG, PNG, HEIC, WebP and TIFF. Each file is copied into
                           DJ Queue's Photos folder; the original is never moved or changed. The post lands in Edit.
      photo add <photo>… --audio <file> [--fit whole|fill] [--title "<title>"] [--json]
                           a video per photo: the photo held for the length of the audio (MP3, M4A, WAV, AIFF, FLAC,
                           CAF, or the sound of an MP4 or MOV; up to 20 minutes). Each lands in Edit as a clip.
                           --fit whole (the default): the whole photo in a 9:16 video, over a blurred copy of itself.
                           --fit fill: the video has the photo's shape and Eric picks the 9:16 crop.
      photo audio <id> <file> [--fit whole|fill] [--json]
                           add that audio to a photo post with one photo (it becomes a video, same id), or change
                           the audio of one that has it. Only while it is in Edit with no day and no post.
      photo audio <id> --fit whole|fill [--json]
                           change how the photo sits in the video (made again from its own audio; the crop resets)
      photo audio <id> --remove [--json]
                           take the audio off: a photo post again
      photo list [--json]  every photo post: stage, photos, title

    A photo post needs no score, never posts to YouTube Shorts, and a carousel longer than a platform takes sends its
    first photos there (X 4, Instagram 10, Facebook 10, Threads 20, TikTok 35). A photo with audio is a clip: it needs
    no score either, posts to YouTube Shorts too, and `djq videos` lists it with `still`.
    """

  struct AudioOut: Codable {
    var video: AgentAPI.VideoSummary
    /// What happened: "added", "changed", "removed", "refitted" (a fit change) or "unchanged" (it had that fit).
    var change: String
    /// For `djq bulk undo`.
    var batchId: String?
  }

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
      let audio = option("--audio")
      let fit = try fitOption()
      let separate = flag("--separate")
      if let bad = args.first(where: { $0.hasPrefix("--") }) { throw CLIError("unknown option \(bad)\n\n\(usage)") }
      let files = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
      guard !files.isEmpty else { throw CLIError("photo add needs at least one file\n\n\(usage)") }
      if audio == nil, fit != nil { throw CLIError("--fit goes with --audio\n\n\(usage)") }
      if let audio {
        // Round 23: a video per photo, each with this audio.
        let r = try StillVideo(store: store).add(photos: files, audio: file(audio), title: title, titleSource: "agent", fit: fit ?? .whole)
        wrote = !r.videos.isEmpty || !r.skipped.isEmpty
        if json {
          try printJSON(AddOut(posts: try r.videos.map { try AgentAPI.summary($0, store: store) }, skipped: r.skipped))
        } else {
          for v in r.videos { print("added \(short(v.id))  \(StillVideo.label)  \(Validation.fmt(v.duration))  \(v.displayName)  (in Edit)") }
          for s in r.skipped { print("skipped \(s.file): \(s.reason)") }
          if r.videos.isEmpty { print("no video made") }
        }
        return r.videos.isEmpty ? 1 : 0
      }
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
    case "audio":
      let remove = flag("--remove")
      let fit = try fitOption()
      if let bad = args.first(where: { $0.hasPrefix("--") }) { throw CLIError("unknown option \(bad)\n\n\(usage)") }
      guard let first = args.first else { throw CLIError("photo audio needs a post id\n\n\(usage)") }
      let v = try resolveVideo(store, first)
      let maker = StillVideo(store: store)
      let change: StillVideo.Change, what: String
      if remove {
        if args.count > 1 || fit != nil { throw CLIError("--remove takes no file and no fit: djq photo audio <id> --remove") }
        change = try maker.removeAudio(videoId: v.id)
        what = "removed"
      } else if args.count == 1, let fit {
        // D12: only the fit. Made again from its own audio.
        change = try maker.setFit(videoId: v.id, fit: fit)
        what = change.batchId == nil ? "unchanged" : "refitted"
      } else {
        guard args.count == 2 else { throw CLIError("photo audio needs one audio file (or --fit, or --remove)\n\n\(usage)") }
        if v.isStill {
          change = try maker.changeAudio(videoId: v.id, audio: file(args[1]), fit: fit)
          what = "changed"
        } else {
          change = try maker.addAudio(to: v.id, audio: file(args[1]), fit: fit ?? .whole)
          what = "added"
        }
      }
      wrote = what != "unchanged"
      if json {
        try printJSON(AudioOut(video: try AgentAPI.summary(change.video, store: store), change: what, batchId: change.batchId))
      } else {
        let now = change.video
        let fitWords = now.still.map { $0.fits == .whole ? "whole photo" : "fills the frame" } ?? ""
        print(what == "removed" ? "\(short(now.id))  audio removed: a photo post again  \(now.displayName)"
              : what == "unchanged" ? "\(short(now.id))  already \(fitWords)  \(now.displayName)"
              : what == "refitted" ? "\(short(now.id))  now \(fitWords)  \(now.displayName)  (in Edit)"
              : "\(short(now.id))  audio \(what): \(StillVideo.label)  \(Validation.fmt(now.duration))  \(fitWords)  \(now.displayName)  (in Edit)")
        if let b = change.batchId { print("  undo: djq bulk undo \(short(b))") }
      }
      return 0
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

  /// `--fit whole|fill` (nil: not given).
  static func fitOption() throws -> StillSource.Fit? {
    guard let raw = option("--fit") else {
      if args.contains("--fit") { throw CLIError("--fit needs whole or fill") }
      return nil
    }
    guard let fit = StillSource.Fit(rawValue: raw) else { throw CLIError("--fit takes whole or fill, not \(raw)") }
    return fit
  }

  static func file(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }
}
