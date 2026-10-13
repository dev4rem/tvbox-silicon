import SwiftUI
import TVCore

#if os(tvOS)
/// Now Playing at the top of a music page, as a small pill like the filter chips beside it: the
/// remote reaches it in a move from the results, and it opens the full-screen player.
struct MusicNowPlayingButton: View {
    @Environment(Store.self) private var store
    var body: some View {
        let music = store.music
        if let track = music.track {
            Button { music.presentsPlayer = true } label: {
                HStack(spacing: 14) {
                    PosterImage(url: track.artwork, symbol: "music.note")
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // Bars in the label's own colour, so they stay visible on the focused white plate.
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: music.phase == .playing)
                    Text([track.title, track.artistLine].joined(separator: " · ")).lineLimit(1)
                }
            }
            .glassPill()
            .accessibilityLabel(Text(L10n.text("Now Playing") + ", " + track.title))
            .padding(.bottom, 16)
        }
    }
}
#endif
