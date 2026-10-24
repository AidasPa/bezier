import AppKit
import BezierCore
import BezierEngine
import Observation
import SwiftUI

/// What every loaded tab's media is doing, for speaker icons and the Mini Player.
@MainActor
@Observable
final class MediaCenter {
    private(set) var states: [UUID: MediaState] = [:]
    /// When each tab last started playing; the Mini Player follows the latest.
    private var lastPlayed: [UUID: Date] = [:]
    /// Closed from the Mini Player; it comes back if the tab plays again.
    private var dismissed: Set<UUID> = []

    func update(_ tabID: UUID, _ media: MediaState?) {
        let wasPlaying = states[tabID]?.isPlaying ?? false
        states[tabID] = media
        if media?.isPlaying == true, !wasPlaying {
            lastPlayed[tabID] = .now
            dismissed.remove(tabID)
        }
        if media == nil { lastPlayed[tabID] = nil }
    }

    func remove(_ tabID: UUID) {
        states[tabID] = nil
        lastPlayed[tabID] = nil
    }

    func dismiss(_ tabID: UUID) { dismissed.insert(tabID) }

    /// The tab to show in the Mini Player: media that has played, newest first, other than `excluding`.
    func miniPlayerTab(excluding selected: UUID?) -> UUID? {
        lastPlayed.filter { $0.key != selected && !dismissed.contains($0.key) && states[$0.key] != nil }
            .max { $0.value < $1.value }?.key
    }
}

/// Bottom of the sidebar: the media playing in a tab you're not looking at. Click it to go
/// back to the tab.
struct MiniPlayer: View {
    let controller: BrowserWindowController
    let tab: BrowserTab
    let media: MediaState
    let palette: ThemePalette

    @State private var hovering = false

    private var content: (any WebContent)? { controller.app.contents.existingContent(for: tab) }

    var body: some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(media.title.isEmpty ? tab.displayTitle : media.title)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                Text(media.artist.isEmpty ? URLInput.displayHost(tab.url) : media.artist)
                    .font(.system(size: 11)).foregroundStyle(palette.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            control(media.isPlaying ? "pause.fill" : "play.fill", help: media.isPlaying ? "Pause" : "Play") {
                content?.perform(.togglePlayback)
            }
            if hovering {
                control(media.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: media.isMuted ? "Unmute" : "Mute") {
                    content?.perform(.setMuted(!media.isMuted))
                }
                if media.hasVideo {
                    control("pip.enter", help: "Picture in Picture") { content?.perform(.pictureInPicture) }
                }
                control("xmark", help: "Stop and Close") {
                    content?.perform(.pause)
                    withAnimation(Motion.spring) { controller.app.media.dismiss(tab.id) }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius + 2, style: .continuous).fill(palette.rowHover))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.select(tab) }
        .pressScale()
        .help("Go to \(tab.displayTitle)")
    }

    @ViewBuilder private var artwork: some View {
        if let url = media.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                fallback
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        ZStack {
            palette.rowHover
            FaviconView(url: tab.faviconURL, pageURL: tab.url, title: tab.displayTitle, size: 20).frame(width: 20, height: 20)
        }
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.8))
        .help(help)
    }
}
