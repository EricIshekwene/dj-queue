import DJQCore
import SwiftUI

/// Round 23 (A1, A5, D8): the Audio row in the Title section, under what the item is.
///
/// - A photo post: "None" and one button, Add audio…, with what it does. Off for a carousel, with the reason (D3).
/// - A video made from a photo: the audio as one compact bar (its name and length), then Change audio… and Remove
///   audio, each off with the reason once the item has a day or posted (D9), and under them how the photo sits in the
///   video: Whole photo | Fill the frame (D12).
///
/// The row only asks: the app picks the file and makes the video (`EditorAppHooks`), and this editor reads the item
/// again when it lands.
struct EditorAudioRow: View {
  @ObservedObject var model: EditorModel

  private var ui: PhotoAudioUI { .shared }
  private var busy: Bool { ui.busy == model.videoId }

  var body: some View {
    if let v = model.video, v.isPhoto || v.isStill {
      // `model.audioBlocker` was read with the item, off the main thread: nothing here reads the store.
      let why: String? = busy ? PhotoAudioUI.busyReason : ui.busy != nil ? "Still making the last video" : model.audioBlocker
      EditorField(label: "Audio", help: v.isStill ? "The audio this video was made with" : "Add an audio file and this photo becomes a video") {
        VStack(alignment: .leading, spacing: DS.space.xs) {
          bar(v)
          if let still = v.still, !busy {
            DSFlowLayout(spacing: 2) {
              DSButton("Change audio…", variant: .ghost, size: .sm, disabledReason: why,
                       tooltip: "Pick another audio file. The video is made again; the crop, text and caption stay") {
                model.appHooks.changeAudio?(v.id)
              }
              .background(ScriptAnchor("Change audio"))
              DSButton("Remove audio", variant: .ghost, size: .sm, disabledReason: why,
                       tooltip: "Back to a photo post with this photo. Undo brings the video back") {
                model.appHooks.removeAudio?(v.id)
              }
              .background(ScriptAnchor("Remove audio"))
            }
            .padding(.leading, -8)
            .accessibilityLabel("Audio: \(still.audioName)")
            fit(v, still, why)
          } else if v.isPhoto, !busy {
            DSButton("Add audio…", icon: "plus", variant: .outline, size: .sm, disabledReason: why,
                     tooltip: "Pick an audio file. The photo becomes a video as long as the audio") {
              model.appHooks.addAudio?(v.id)
            }
            .background(ScriptAnchor(why == nil ? "Add audio" : "Add audio off: \(why ?? "")"))
            EditorHint(v.isCarousel ? StillVideo.carouselReason : StillVideo.addHint)
          }
        }
      }
      .padding(.top, DS.space.xxs)
    }
  }

  /// D12: how the photo sits in the 9:16 video. Changing it makes the video again (the app does; the audio stays).
  private func fit(_ v: Video, _ still: StillSource, _ why: String?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      DSSegmented(selection: Binding(get: { still.fits }, set: { model.appHooks.setAudioFit?(v.id, $0) }),
                  segments: StillSource.Fit.allCases.map { f in
                    DSSegment(value: f, title: f.displayName,
                              tooltip: f == .whole ? "Show the whole photo in the video, over a blurred copy of itself. Nothing to crop"
                                : "Let the photo fill the video. You pick which part shows",
                              disabledReason: f == still.fits ? nil : why)
                  }, size: .sm, fullWidth: true)
        .background(ScriptAnchor("Fit \(still.fits.rawValue)"))
        .accessibilityLabel("How the photo sits in the video")
      EditorHint(StillVideo.fitHint(still.fits))
    }
    .padding(.top, DS.space.xxs)
  }

  /// The audio as one row: a note, its name and its length, or "None", or the progress while the video is made.
  private func bar(_ v: Video) -> some View {
    HStack(spacing: DS.space.xs) {
      if busy {
        DSSpinner(size: 12)
        Text(ui.line).font(DS.type.callout.monospacedDigit()).foregroundStyle(DS.color.text).lineLimit(1)
      } else {
        Image(systemName: v.isStill ? "music.note" : "speaker.slash").font(.system(size: 12, weight: .medium))
          .foregroundStyle(v.isStill ? DS.color.text : DS.color.textTertiary)
          .frame(width: 16)
        if let s = v.still {
          Text(s.audioName).font(DS.type.callout).foregroundStyle(DS.color.text).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: DS.space.xs)
          Text(Fmt.duration(s.audioDuration)).font(DS.type.callout.monospacedDigit()).foregroundStyle(DS.color.textSecondary)
        } else {
          Text("None").font(DS.type.callout).foregroundStyle(DS.color.textSecondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DS.space.sm)
    .frame(height: DS.size.controlMd)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dsSurface(DS.color.surfaceSunken, radius: DS.radius.sm, border: nil)
    .dsTooltip(v.still.map { "\($0.audioName) · \(Fmt.duration($0.audioDuration))" })
    .background(ScriptAnchor("Audio row \(busy ? "busy" : v.still.map { AppModel.audioLine($0) } ?? "None")"))
  }
}

/// Over the editor while its item's video is being made: nothing in it can change the item meanwhile, and it says how
/// far along the video is.
struct EditorMakingVideo: View {
  var body: some View {
    let ui = PhotoAudioUI.shared
    ZStack {
      DS.color.canvas.opacity(0.6)
      VStack(spacing: DS.space.sm) {
        DSProgress(value: ui.progress, label: "Making the video", valueLabel: "\(Int((ui.progress * 100).rounded())) %")
          .frame(width: 260)
        Text("The editor carries on as the clip editor when it's done.").font(DS.type.caption).foregroundStyle(DS.color.textSecondary)
      }
      .padding(DS.space.lg)
      .dsFloatingSurface(radius: DS.radius.lg, elevation: DS.elevation.e2)
      .background(ScriptAnchor("Making the video"))
    }
    .contentShape(Rectangle())
    .accessibilityLabel(ui.line)
  }
}
