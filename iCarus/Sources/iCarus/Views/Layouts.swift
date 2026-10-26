import SwiftUI

// Each layout is just an arrangement of the shared components.
// To add a new layout: add a case to LayoutKind, write a view here,
// and add it to the switch in PlayerView.

struct StandardLayout: View {
    @Environment(\.skin) private var skin

    var body: some View {
        VStack(spacing: skin.spacing) {
            ArtworkPlaceholder()
                .padding(.horizontal, skin.spacing * 2)

            NowPlayingInfo()
            SeekBar()
            TransportControls()
            VolumeSlider()
                .padding(.horizontal, skin.spacing * 2)

            PlaylistView()
                .frame(minHeight: 140)
        }
        .padding(skin.spacing)
    }
}

struct CompactLayout: View {
    @Environment(\.skin) private var skin

    var body: some View {
        VStack(spacing: skin.spacing * 0.6) {
            HStack(spacing: skin.spacing) {
                NowPlayingInfo(alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TransportControls()
            }
            SeekBar()
        }
        .padding(skin.spacing)
    }
}
