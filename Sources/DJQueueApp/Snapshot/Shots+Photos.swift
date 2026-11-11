import DJQCore
import SwiftUI

/// Round 21 shots (prefix r21-photos): photo posts where the other lists don't already show them. The import sheet
/// with a carousel longer than X takes, quick look on a carousel, Single view, the Queue and Library narrowed to
/// photos, ⌘K, the post inspector and the Photo shape row. The Edit, Queue and Library shots of the other lists show
/// the sample photo posts beside clips. The click-through is `PhotoImportScript`.
extension SnapshotShots {
  static func photos(_ c: SnapshotContext) -> [Shot] {
    let ui = BrowseUI.shared
    func prep(_ m: AppModel) {
      ui.reset()
      m.postsSelection = nil
      ListPrefs.shared.reset()
      PhotoImportUI.shared.dropTargeted = false
      SettingsUIState.shared.reset()
    }
    func post(_ m: AppModel, carousel: Bool, where ok: (Video) -> Bool = { _ in true }) -> Video? {
      m.videos.first { $0.isPhoto && $0.isCarousel == carousel && ok($0) }
    }
    return [
      c.main("r21-photos-import-sheet") { m in
        prep(m)
        m.setViewMode(.wide, for: .edit)
        m.screen = .edit
        // Six photos: more than X takes, so the sheet says which platform gets fewer.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("djq-r21-shot-\(UUID().uuidString)")
        if let files = try? SampleData.photoFiles(store: c.store, count: 6, dir: dir, offset: 1, name: "night") {
          m.photoImportRequest = PhotoImportRequest(files: files)
        }
      },
      c.main("r21-photos-import-toast") { m in
        prep(m)
        m.setViewMode(.wide, for: .edit)
        m.screen = .edit
        m.show(DSToastModel(message: "Added 1 carousel to Edit", detail: "6 photos\nSkipped set-list.pdf: not a photo format DJ Queue takes (JPEG, PNG, HEIC, WebP or TIFF)",
                            tone: .success, actionTitle: "Open", action: {}, duration: 10))
      },
      c.main("r21-photos-quicklook") { m in
        prep(m)
        m.setViewMode(.wide, for: .edit)
        m.screen = .edit
        m.previewVideo = post(m, carousel: true)
      },
      c.main("r21-photos-edit-single") { m in
        prep(m)
        m.setViewMode(.single, for: .edit)
        m.screen = .edit
        if let v = post(m, carousel: true, where: { v in m.editList.contains { $0.id == v.id } }) {
          ListPrefs.shared.setSearch(.edit, m.displayName(v))
        }
      },
      c.main("r21-photos-queue-list") { m in
        prep(m)
        m.setViewMode(.list, for: .queue)
        m.screen = .queue
        ListPrefs.shared.setFilter(.queue, ListFilterKey.kind, ListFilterKey.photoKind)
      },
      c.main("r21-photos-library-kind") { m in
        prep(m)
        m.setViewMode(.grid, for: .library)
        m.screen = .library
        ListPrefs.shared.setFilter(.library, ListFilterKey.kind, ListFilterKey.photoKind)
      },
      c.main("r21-photos-library-cards") { m in
        prep(m)
        m.setViewMode(.wide, for: .library)
        m.screen = .library
        ListPrefs.shared.setFilter(.library, ListFilterKey.kind, ListFilterKey.photoKind)
      },
      c.main("r21-photos-library-quicklook") { m in
        prep(m)
        m.setViewMode(.grid, for: .library)
        m.screen = .library
        ui.quickLook = post(m, carousel: true)
      },
      c.main("r21-photos-palette") { m in
        prep(m)
        m.setViewMode(.wide, for: .edit)
        m.screen = .edit
        ui.paletteQuery = "photo"
        m.showPalette = true
      },
      c.main("r21-photos-palette-post") { m in
        prep(m)
        m.screen = .queue
        ui.paletteClipId = post(m, carousel: true)?.id
        m.showPalette = true
      },
      c.main("r21-photos-posts-inspector") { m in
        prep(m)
        ListPrefs.shared.setStatus(.posts, nil)
        m.screen = .posts
        let photoIds = Set(m.videos.filter(\.isPhoto).map(\.id))
        m.postsSelection = m.posts.first { photoIds.contains($0.videoId) }?.id
        if let id = m.postsSelection.flatMap({ id in m.posts.first { $0.id == id }?.videoId }), let v = m.video(id) {
          ListPrefs.shared.setSearch(.posts, m.displayName(v))
        }
      },
      c.main("r21-photos-settings-shape") { m in
        prep(m)
        SettingsUIState.shared.reset()
        m.setViewMode(.wide, for: .edit)
        m.screen = .edit
        m.settingsSection = .newClipDefaults
        m.showSettings = true
        var d = m.settings.defaults
        d.photoAspect = .r9x16
        SettingsUIState.shared.draft = d
      },
      c.view("r21-photos-revert", width: 10, height: 10) {
        prep(c.model)
        for s in [Screen.edit, .queue, .library] { c.model.viewModes[s] = nil }
        return AnyView(Color.clear)
      },
    ]
  }
}
