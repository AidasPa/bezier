import AppKit
import SwiftUI

/// ⌃Tab: recent tabs as cards in the middle of the window. Keep holding Control and press Tab
/// (⇧ to go back) to move along; let go to switch, Escape to stay. A quick ⌃Tab just flips to
/// the previous tab without showing anything.
@MainActor
@Observable
final class TabSwitcherModel {
    struct Item: Identifiable {
        let id: UUID
        let title: String
        let pageURL: URL?
        let faviconURL: URL?
        let thumbnail: NSImage?
    }

    var items: [Item] = []
    var selected = 0
    @ObservationIgnored var onPick: ((Int) -> Void)?
}

struct TabSwitcherView: View {
    let model: TabSwitcherModel

    static let cardSize = CGSize(width: 176, height: 110)

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                card(item, selected: index == model.selected)
                    .onTapGesture { model.onPick?(index) }
            }
        }
        .padding(12)
        .modifier(GlassPanel(cornerRadius: 24))
        .padding(40)                                 // room for the panel's shadow
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: model.selected)
    }

    private func card(_ item: TabSwitcherModel.Item, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06))
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .top)
                        .clipped()
                } else {
                    FaviconView(url: item.faviconURL, pageURL: item.pageURL, title: item.title, size: 32)
                        .frame(width: 34, height: 34)
                }
            }
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(selected ? 0.18 : 0.08), radius: selected ? 8 : 3, y: 2)
            HStack(spacing: 6) {
                FaviconView(url: item.faviconURL, pageURL: item.pageURL, title: item.title, size: 14)
                    .frame(width: 14, height: 14)
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(width: Self.cardSize.width, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(selected ? 0.12 : 0)))
        .scaleEffect(selected ? 1.03 : 1)
        .contentShape(Rectangle())
    }
}

extension NSImage {
    /// A real smaller bitmap (keeps 2× pixels for Retina), so thumbnails don't hold full pages.
    func downscaled(toWidth width: CGFloat) -> NSImage {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let scale = min(1, width * 2 / CGFloat(cg.width))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return self }
        return NSImage(cgImage: scaled, size: NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2))
    }
}
