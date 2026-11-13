import CoreGraphics
import Foundation

/// New clip defaults (round 2 #10), edited in Settings. Edits and versions store only Eric's overrides; every
/// field they leave nil resolves from here, mechanically (no guessing). `ResolvedEdit` / `ResolvedVersion`
/// report which fields are defaults so the editor can show "Default" vs "Custom" with a reset.
public struct NewClipDefaults: Codable, Sendable, Hashable {
  public enum CropAnchor: String, Codable, Sendable, CaseIterable {
    case centre, leftThird, rightThird, lastUsed
    public var displayName: String {
      switch self {
      case .centre: "Centre"
      case .leftThird: "Left third"
      case .rightThird: "Right third"
      case .lastUsed: "Same as last crop"
      }
    }
  }

  public enum TrimMode: String, Codable, Sendable, CaseIterable {
    case markers, wholeFile
    public var displayName: String { self == .markers ? "Eric's markers" : "Whole file" }
  }

  public enum TextTiming: String, Codable, Sendable, CaseIterable {
    case whole, firstSeconds
    public var displayName: String { self == .whole ? "Whole clip" : "First seconds" }
  }

  /// Where a clip's overlay text comes from when no version sets it. Never derived/tidied: the title as Eric
  /// chose it, the raw marker tag verbatim, or nothing.
  public enum TextSource: String, Codable, Sendable, CaseIterable {
    case title, rawTag, empty
    public var displayName: String {
      switch self {
      case .title: "Title"
      case .rawTag: "Raw marker tag"
      case .empty: "No text until I type it"
      }
    }
  }

  public enum CoverFrame: String, Codable, Sendable, CaseIterable {
    case trimStart, markerIn, offsetSeconds
    public var displayName: String {
      switch self {
      case .trimStart: "First frame of the trim"
      case .markerIn: "Marker in-point"
      case .offsetSeconds: "Seconds into the trim"
      }
    }
  }

  // Frame
  public var aspect: Aspect = .r9x16
  public var cropAnchor: CropAnchor = .centre
  // Trim
  public var trimMode: TrimMode = .markers
  public var extraSecondsBefore: Double = 0
  public var extraSecondsAfter: Double = 0
  // Text
  public var textStyle: TextStyle = .box  // Q11
  public var textSize: Double = 64  // Q13 (medium)
  public var textPosX: Double = 0.5
  public var textPosY: Double = 0.5  // Q12 (centre)
  public var textAlign: TextAlign = .center
  public var textTiming: TextTiming = .whole
  public var textFirstSeconds: Double = 3
  public var textSource: TextSource = .title
  public var noTextForTalking: Bool = true
  // Cover
  public var coverIncludesText: Bool = true  // Q18
  public var coverFrame: CoverFrame = .trimStart
  public var coverOffsetSeconds: Double = 1
  // Caption
  public var captionTemplateId: String = "set-link"
  /// Round 7: none by default — Eric's own hashtag groups (Settings → Captions & titles) are opt-in.
  public var hashtagSetIds: [String] = []
  public var extraHashtags: [String] = []
  /// `{text}` = overlay text on one line, else the title, else the raw tag. Over the title limit, `{text}` is
  /// shortened (the rest of the template is kept).
  /// Round 7: kept in step with the default entry of `Settings.youtubeTitleTemplates` on every save (older builds
  /// and a rollback read this field); the list + `youtubeTitleTemplateId` are the source of truth.
  public var youtubeTitleTemplate: String = "{text} | DJ Lovd"  // Q17
  /// Round 7: the default YouTube title template (`Settings.youtubeTitleTemplates` id).
  public var youtubeTitleTemplateId: String = "text-djlovd"
  /// Caption template id per platform, used when the clip's version didn't choose a template.
  public var platformCaptionTemplates: [Platform: String] = [:]
  // Posting
  /// Platforms a new clip posts to (of the enabled ones). A clip can still turn one on/off in the editor.
  public var platforms: Set<Platform> = Set(Platform.allCases)
  /// Platforms whose safe zones the editor shows by default.
  public var safeZonePlatforms: Set<Platform> = [.tiktok, .instagram]
  /// Kind for new clips (videos.json `content-type: talking` still wins).
  public var kind: Kind = .djVid
  /// Round 21 (D5): the shape a new photo post is cropped to. Every photo of a carousel uses the post's one aspect.
  public var photoAspect: Aspect = .r4x5

  public init() {}

  enum CodingKeys: String, CodingKey {
    case aspect, cropAnchor, trimMode, extraSecondsBefore, extraSecondsAfter, textStyle, textSize, textPosX, textPosY,
         textAlign, textTiming, textFirstSeconds, textSource, noTextForTalking, coverIncludesText, coverFrame,
         coverOffsetSeconds, captionTemplateId, hashtagSetIds, extraHashtags, youtubeTitleTemplate, youtubeTitleTemplateId,
         platformCaptionTemplates, platforms, safeZonePlatforms, kind, photoAspect
  }

  /// Every key is optional, so stored JSON from an older build (or a hand-edited one) keeps working.
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    let z = NewClipDefaults()
    func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
    aspect = v(.aspect, z.aspect)
    cropAnchor = v(.cropAnchor, z.cropAnchor)
    trimMode = v(.trimMode, z.trimMode)
    extraSecondsBefore = v(.extraSecondsBefore, z.extraSecondsBefore)
    extraSecondsAfter = v(.extraSecondsAfter, z.extraSecondsAfter)
    textStyle = v(.textStyle, z.textStyle)
    textSize = v(.textSize, z.textSize)
    textPosX = v(.textPosX, z.textPosX)
    textPosY = v(.textPosY, z.textPosY)
    textAlign = v(.textAlign, z.textAlign)
    textTiming = v(.textTiming, z.textTiming)
    textFirstSeconds = v(.textFirstSeconds, z.textFirstSeconds)
    textSource = v(.textSource, z.textSource)
    noTextForTalking = v(.noTextForTalking, z.noTextForTalking)
    coverIncludesText = v(.coverIncludesText, z.coverIncludesText)
    coverFrame = v(.coverFrame, z.coverFrame)
    coverOffsetSeconds = v(.coverOffsetSeconds, z.coverOffsetSeconds)
    captionTemplateId = v(.captionTemplateId, z.captionTemplateId)
    hashtagSetIds = v(.hashtagSetIds, z.hashtagSetIds)
    extraHashtags = v(.extraHashtags, z.extraHashtags)
    youtubeTitleTemplate = v(.youtubeTitleTemplate, z.youtubeTitleTemplate)
    youtubeTitleTemplateId = v(.youtubeTitleTemplateId, z.youtubeTitleTemplateId)
    platformCaptionTemplates = v(.platformCaptionTemplates, z.platformCaptionTemplates)
    platforms = v(.platforms, z.platforms)
    safeZonePlatforms = v(.safeZonePlatforms, z.safeZonePlatforms)
    kind = v(.kind, z.kind)
    photoAspect = v(.photoAspect, z.photoAspect)
  }

  /// Default text timing relative to the trim start (nil, nil = whole clip).
  public var textWindow: (start: Double?, end: Double?) {
    textTiming == .whole ? (nil, nil) : (0, max(0.3, textFirstSeconds))
  }

  /// Default trim for a clip: markers (± extra seconds, inside the file) or the whole file.
  public func trim(for v: Video) -> TrimRange {
    let d = v.duration
    switch trimMode {
    case .wholeFile:
      return TrimRange(start: 0, end: d)
    case .markers:
      let a = max(0, (v.markerIn ?? 0) - (v.markerIn == nil ? 0 : extraSecondsBefore))
      var b = (v.markerOut ?? d) + (v.markerOut == nil ? 0 : extraSecondsAfter)
      if d > 0 { b = min(d, b) }
      return b > a ? TrimRange(start: a, end: b) : TrimRange(start: 0, end: d)
    }
  }

  /// Default crop of `aspect` on a `source`-sized picture for the anchor (even pixels, like the export).
  /// `lastUsed` is a normalised crop centre (0…1) from the most recent confirmed crop; nil falls back to centre.
  public func defaultCrop(source: CGSize, aspect: Aspect, lastUsed: CGPoint? = nil) -> CropRect {
    let sw = Double(source.width), sh = Double(source.height)
    let c = Media.centredCrop(aspect: aspect, sourceWidth: Int(sw), sourceHeight: Int(sh))
    var cx = 0.5, cy = 0.5
    switch cropAnchor {
    case .centre: break
    case .leftThird: cx = 1.0 / 3
    case .rightThird: cx = 2.0 / 3
    case .lastUsed: if let p = lastUsed { cx = Double(p.x); cy = Double(p.y) }
    }
    var r = c
    r.x = min(max(0, cx * sw - c.w / 2), sw - c.w)
    r.y = min(max(0, cy * sh - c.h / 2), sh - c.h)
    let px = Media.pixelCrop(r, sourceWidth: Int(sw), sourceHeight: Int(sh))
    return CropRect(x: px.minX, y: px.minY, w: px.width, h: px.height)
  }

  /// The default crop for `v`. A video made from a photo (round 23) is always centred: the anchor in Settings is where
  /// the DJ stands in the camera's frame, which says nothing about a flyer or a photo.
  public func defaultCrop(for v: Video, source: CGSize, aspect: Aspect, lastUsed: CGPoint? = nil) -> CropRect {
    guard v.isStill else { return defaultCrop(source: source, aspect: aspect, lastUsed: lastUsed) }
    var centred = self
    centred.cropAnchor = .centre
    return centred.defaultCrop(source: source, aspect: aspect)
  }
}

/// Edit fields that can follow the defaults (for "Default"/"Custom" badges and resets).
public enum EditField: String, Codable, Sendable, CaseIterable {
  case aspect, crop, trimIn, trimOut, coverTime, coverIncludesText, platforms
}

/// An edit with the defaults applied. `defaulted` lists the fields that follow `Settings.defaults`.
public struct ResolvedEdit: Sendable, Hashable, Codable {
  public var aspect: Aspect
  /// The confirmed crop, else the default anchor crop when the source size is known, else nil.
  public var crop: CropRect?
  /// True when Eric confirmed the crop (validation needs it; Make ready with defaults confirms the default).
  public var cropConfirmed: Bool
  /// Absolute seconds in the file.
  public var trimIn: Double
  public var trimOut: Double
  /// Absolute seconds in the file.
  public var coverTime: Double
  public var coverIncludesText: Bool
  public var platformTrims: [Platform: TrimRange]
  /// Effective skipped platforms (explicit skips + platforms the defaults leave out and the clip didn't turn on).
  public var skippedPlatforms: Set<Platform>
  public var defaulted: Set<EditField>
  /// Round 30: the version whose own trim this is (`Version.trimIn/Out`); nil = the clip's trim. `trimIn`, `trimOut`
  /// and `platformTrims` are that version's then, and a default cover frame follows its start.
  public var trimVersion: Int? = nil

  public func isDefault(_ f: EditField) -> Bool { defaulted.contains(f) }
  /// True when the trim is a version's own, not the clip's (round 30).
  public var hasVersionTrim: Bool { trimVersion != nil }

  public func trim(platform: Platform? = nil) -> TrimRange {
    if let p = platform, let t = platformTrims[p] { return t }
    return TrimRange(start: trimIn, end: trimOut)
  }

  public func isSkipped(_ p: Platform) -> Bool { skippedPlatforms.contains(p) }

  enum CodingKeys: String, CodingKey {
    case aspect, crop, cropConfirmed, trimIn, trimOut, coverTime, coverIncludesText, platformTrims, skippedPlatforms, defaulted
    case trimVersion
  }

  /// Deterministic JSON (sets sorted, platform keys as strings).
  public func encode(to enc: Encoder) throws {
    var c = enc.container(keyedBy: CodingKeys.self)
    try c.encode(aspect, forKey: .aspect); try c.encodeIfPresent(crop, forKey: .crop)
    try c.encode(cropConfirmed, forKey: .cropConfirmed); try c.encode(trimIn, forKey: .trimIn)
    try c.encode(trimOut, forKey: .trimOut); try c.encode(coverTime, forKey: .coverTime)
    try c.encode(coverIncludesText, forKey: .coverIncludesText)
    try c.encode(Dictionary(uniqueKeysWithValues: platformTrims.map { ($0.key.rawValue, $0.value) }), forKey: .platformTrims)
    try c.encode(skippedPlatforms.map(\.rawValue).sorted(), forKey: .skippedPlatforms)
    try c.encode(defaulted.map(\.rawValue).sorted(), forKey: .defaulted)
    try c.encodeIfPresent(trimVersion, forKey: .trimVersion)
  }

  public init(from dec: Decoder) throws {
    let c = try dec.container(keyedBy: CodingKeys.self)
    aspect = try c.decode(Aspect.self, forKey: .aspect)
    crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
    cropConfirmed = try c.decode(Bool.self, forKey: .cropConfirmed)
    trimIn = try c.decode(Double.self, forKey: .trimIn)
    trimOut = try c.decode(Double.self, forKey: .trimOut)
    coverTime = try c.decode(Double.self, forKey: .coverTime)
    coverIncludesText = try c.decode(Bool.self, forKey: .coverIncludesText)
    let pt = try c.decodeIfPresent([String: TrimRange].self, forKey: .platformTrims) ?? [:]
    platformTrims = Dictionary(uniqueKeysWithValues: pt.compactMap { k, v in Platform(rawValue: k).map { ($0, v) } })
    skippedPlatforms = Set((try c.decode([String].self, forKey: .skippedPlatforms)).compactMap(Platform.init))
    defaulted = Set((try c.decode([String].self, forKey: .defaulted)).compactMap(EditField.init))
    trimVersion = try c.decodeIfPresent(Int.self, forKey: .trimVersion)
  }

  public init(aspect: Aspect, crop: CropRect?, cropConfirmed: Bool, trimIn: Double, trimOut: Double, coverTime: Double,
              coverIncludesText: Bool, platformTrims: [Platform: TrimRange], skippedPlatforms: Set<Platform>,
              defaulted: Set<EditField>) {
    self.aspect = aspect; self.crop = crop; self.cropConfirmed = cropConfirmed; self.trimIn = trimIn
    self.trimOut = trimOut; self.coverTime = coverTime; self.coverIncludesText = coverIncludesText
    self.platformTrims = platformTrims; self.skippedPlatforms = skippedPlatforms; self.defaulted = defaulted
  }
}

public enum EditResolver {
  /// Pure resolution. `sourceSize` (or the video's cached size) is needed for the default crop.
  /// `version` (round 30): the version being shown, posted or rendered. When it has its own trim, the result's trim,
  /// per-platform trims and default cover frame are that version's (`trimVersion` says so); an explicit cover outside
  /// it falls back to the default rule inside it. nil, or a version that follows the clip = the clip's trim.
  public static func resolve(_ e: Edit, video v: Video, defaults d: NewClipDefaults, sourceSize: CGSize? = nil,
                             lastUsedCrop: CGPoint? = nil, version: Version? = nil) -> ResolvedEdit {
    if let photos = v.photos { return resolvePhotos(e, photos, defaults: d) }
    var defaulted = Set<EditField>()
    let aspect = e.aspectOverride ?? d.aspect
    if e.aspectOverride == nil { defaulted.insert(.aspect) }
    let size = sourceSize ?? v.sourceWidth.flatMap { w in v.sourceHeight.map { CGSize(width: w, height: $0) } }
    var crop = e.crop
    var confirmed = e.crop != nil
    if crop == nil {
      defaulted.insert(.crop)
      if let size, size.width > 0, size.height > 0 {
        crop = d.defaultCrop(for: v, source: size, aspect: aspect, lastUsed: lastUsedCrop)
        // D12: a made video that shows the whole photo is 9:16 already. Its crop is the whole frame and needs no confirming.
        if v.still?.fits == .whole, aspect == .r9x16 {
          crop = CropRect(x: 0, y: 0, w: Double(size.width), h: Double(size.height))
          confirmed = true
        }
      }
    }
    let def = d.trim(for: v)
    if e.trimIn == nil { defaulted.insert(.trimIn) }
    if e.trimOut == nil { defaulted.insert(.trimOut) }
    var tIn = e.trimIn ?? def.start, tOut = e.trimOut ?? def.end
    if tOut <= tIn {  // one side overridden past the other's default: fall back to the file end/start
      if e.trimIn != nil { tOut = v.duration > tIn ? v.duration : tIn + 0.3 } else { tIn = 0 }
    }
    var platformTrims = e.platformTrims
    var trimVersion: Int? = nil
    if let own = version.flatMap({ ownTrim($0, video: v) }) {
      tIn = own.start; tOut = own.end
      platformTrims = version?.platformTrims ?? [:]
      trimVersion = version?.number
      defaulted.remove(.trimIn); defaulted.remove(.trimOut)
    }
    let cover: Double
    // The clip's one cover frame is used when it's inside the trim being resolved; outside it (a version's own trim, or a
    // clip trim changed from the CLI) the default rule picks one inside, so a cover is always a frame of the video.
    if let t = e.coverTime, t >= tIn - 0.001, t <= tOut + 0.001 { cover = t } else {
      defaulted.insert(.coverTime)  // also when a picked frame is outside this trim: what shows is the default
      switch d.coverFrame {
      case .trimStart: cover = tIn
      case .markerIn: cover = min(max(v.markerIn ?? tIn, tIn), tOut)
      case .offsetSeconds: cover = min(tIn + max(0, d.coverOffsetSeconds), max(tIn, tOut - 0.05))
      }
    }
    if e.coverIncludesTextOverride == nil { defaulted.insert(.coverIncludesText) }
    let skipped = Set(Platform.allCases.filter { e.isSkipped($0, defaults: d) })
    if e.skippedPlatforms.isEmpty && e.includedPlatforms.isEmpty { defaulted.insert(.platforms) }
    var r = ResolvedEdit(aspect: aspect, crop: crop, cropConfirmed: confirmed, trimIn: tIn, trimOut: tOut,
                         coverTime: cover, coverIncludesText: e.coverIncludesTextOverride ?? d.coverIncludesText,
                         platformTrims: platformTrims, skippedPlatforms: skipped, defaulted: defaulted)
    r.trimVersion = trimVersion
    return r
  }

  /// A version's own trim, kept inside the file (round 30). nil when it has none, or one that leaves under 0.3 s.
  public static func ownTrim(_ ver: Version, video v: Video) -> TrimRange? {
    guard !v.isPhoto, let a = ver.trimIn, let b = ver.trimOut else { return nil }
    let lo = max(0, a), hi = v.duration > 0 ? min(v.duration, b) : b
    return hi - lo >= 0.3 ? TrimRange(start: lo, end: hi) : nil
  }

  /// A photo post (round 21). The aspect follows `defaults.photoAspect`; `crop` is the first photo's (every photo
  /// resolves through `PhotoRules.crop`), confirmed when each photo has its own; the "trim" is one unit per photo
  /// (0…count), so a text's window reads as a range of photos; platforms that take no photos are always skipped.
  static func resolvePhotos(_ e: Edit, _ photos: [PhotoItem], defaults d: NewClipDefaults) -> ResolvedEdit {
    var defaulted: Set<EditField> = [.trimIn, .trimOut, .coverTime]
    let aspect = PhotoRules.aspect(e, defaults: d)
    if e.aspectOverride == nil { defaulted.insert(.aspect) }
    let confirmed = !photos.isEmpty && photos.allSatisfy { PhotoRules.hasOwnCrop($0, edit: e, aspect: aspect) }
    if !confirmed { defaulted.insert(.crop) }
    if e.coverIncludesTextOverride == nil { defaulted.insert(.coverIncludesText) }
    let never = Set(Platform.allCases.filter { !$0.supportsPhotos })
    let skipped = Set(Platform.allCases.filter { e.isSkipped($0, defaults: d) }).union(never)
    if e.skippedPlatforms.subtracting(never).isEmpty && e.includedPlatforms.subtracting(never).isEmpty { defaulted.insert(.platforms) }
    return ResolvedEdit(aspect: aspect, crop: photos.first.map { PhotoRules.crop(for: $0, edit: e, aspect: aspect) },
                        cropConfirmed: confirmed, trimIn: 0, trimOut: Double(photos.count), coverTime: 0,
                        coverIncludesText: e.coverIncludesTextOverride ?? d.coverIncludesText, platformTrims: [:],
                        skippedPlatforms: skipped, defaulted: defaulted)
  }

  /// Clears the override fields that belong to `field` (the editor's "Reset to default").
  public static func reset(_ e: inout Edit, _ field: EditField) {
    switch field {
    case .aspect: e.aspectOverride = nil
    case .crop: e.crop = nil; e.photoCrops = [:]
    case .trimIn: e.trimIn = nil
    case .trimOut: e.trimOut = nil
    case .coverTime: e.coverTime = nil
    case .coverIncludesText: e.coverIncludesTextOverride = nil
    case .platforms: e.skippedPlatforms = []; e.includedPlatforms = []
    }
  }
}

extension Store {
  /// The edit with defaults applied. Uses `sourceSize`, else the video's cached size, for the default crop.
  /// `version` (round 30): whose trim to use. A version with its own trim gets it; one without (or an unreadable
  /// versions row) gets the clip's. Version 1 by default: what the clip's tiles, proxies and readiness show.
  public func resolvedEdit(videoId: String, version: Int = 1, sourceSize: CGSize? = nil,
                           settings: Settings? = nil) throws -> ResolvedEdit {
    guard let v = try video(id: videoId) else { throw StoreError.corruptRow("videos", videoId) }
    let s = try settings ?? self.settings()
    return EditResolver.resolve(try edit(videoId: videoId), video: v, defaults: s.defaults, sourceSize: sourceSize,
                                lastUsedCrop: s.defaults.cropAnchor == .lastUsed ? try lastCropCentre() : nil,
                                version: rawVersion(videoId: videoId, number: version))
  }

  /// The stored version `number` as it is (no carry-forward), nil when it isn't stored or the rows can't be read.
  public func rawVersion(videoId: String, number: Int) -> Version? {
    (try? versions(videoId: videoId))?.first { $0.number == number }
  }

  /// Normalised centre of the most recently confirmed crop (for the "Same as last crop" anchor).
  public func lastCropCentre() throws -> CGPoint? {
    struct P: Codable { var x: Double; var y: Double }
    return try kv("defaults.lastCropCentre", as: P.self).map { CGPoint(x: $0.x, y: $0.y) }
  }

  /// Caches the source picture size on the video row.
  public func setSourceSize(_ id: String, width: Int, height: Int) throws {
    try db.run("UPDATE videos SET source_width=?, source_height=? WHERE id=?", [width, height, id])
  }
}
