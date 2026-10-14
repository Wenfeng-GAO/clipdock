import SwiftUI
import UIKit

/// 3-column video picker (mock screen 02). Thumbnails, duration, size, selection chrome.
struct VideoPickerGrid: View {
    @ObservedObject var viewModel: HomeViewModel
    let videos: [VideoAssetSummary]
    let thumbnailProvider: any VideoThumbnailProviding

    @Environment(\.displayScale) private var displayScale
    @State private var gridWidth: CGFloat = 0

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
    ]

    private var thumbnailTargetSize: CGSize {
        let sidePoints: CGFloat = gridWidth > 1 ? max((gridWidth - 6) / 3, 1) : 120
        let scale: CGFloat = displayScale > 0 ? displayScale : 2
        let side = sidePoints * scale
        return CGSize(width: side, height: side)
    }

    private var cacheToken: String {
        let ids = videos.map(\.id).joined(separator: "|")
        return "\(Int(thumbnailTargetSize.width))x\(Int(thumbnailTargetSize.height))|\(ids)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(videos) { video in
                    let content = viewModel.pickerCellContent(for: video)
                    VideoPickerThumbnailCell(
                        assetID: video.id,
                        leadingText: content.leadingText,
                        sizeText: content.sizeText,
                        isSelected: viewModel.selectedVideoIDs.contains(video.id),
                        targetSize: thumbnailTargetSize,
                        thumbnailProvider: thumbnailProvider,
                        onToggle: { viewModel.toggleSelection(for: video.id) }
                    )
                    .task {
                        viewModel.ensureSizeLoaded(for: video.id)
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PickerGridWidthPreference.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(PickerGridWidthPreference.self) { width in
                guard abs(width - gridWidth) > 0.5 else { return }
                gridWidth = width
            }
            .onAppear {
                refreshThumbnailCache()
            }
            .onChange(of: cacheToken) { _, _ in
                refreshThumbnailCache()
            }
            .onDisappear {
                thumbnailProvider.stopThumbnailCache()
            }

            Text(verbatim: L10n.tr("☁︎ Sizes for videos that are only in iCloud are estimates."))
                .font(.system(size: 12))
                .foregroundStyle(PickerPalette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
    }

    private func refreshThumbnailCache() {
        let target = thumbnailTargetSize
        guard target.width > 1 else {
            thumbnailProvider.stopThumbnailCache()
            return
        }
        thumbnailProvider.updateThumbnailCache(localIdentifiers: videos.map(\.id), targetSize: target)
    }
}

private struct VideoPickerThumbnailCell: View {
    let assetID: String
    let leadingText: String
    let sizeText: String
    let isSelected: Bool
    let targetSize: CGSize
    let thumbnailProvider: any VideoThumbnailProviding
    let onToggle: () -> Void

    @State private var image: UIImage?

    private var thumbnailTaskID: String {
        "\(assetID)|\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))"
    }

    var body: some View {
        Button(action: onToggle) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    thumbnail
                }
                .overlay(alignment: .bottomLeading) {
                    Text(verbatim: leadingText)
                        .font(.system(size: 10))
                        .foregroundStyle(PickerPalette.duration)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.55), radius: 1, y: 0)
                        .padding(4)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(verbatim: sizeText)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(PickerPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Text(verbatim: "✓")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 20, height: 20)
                            .background(PickerPalette.ink, in: Circle())
                            .padding(5)
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(PickerPalette.ink, lineWidth: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(leadingText), \(sizeText)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: thumbnailTaskID) {
            guard targetSize.width > 1, targetSize.height > 1 else { return }
            let stream = thumbnailProvider.thumbnailImages(localIdentifier: assetID, targetSize: targetSize)
            for await next in stream {
                image = next
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [PickerPalette.thumbnailTop, PickerPalette.thumbnailBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private enum PickerPalette {
    static let thumbnailTop = Color(red: 42 / 255, green: 51 / 255, blue: 64 / 255)
    static let thumbnailBottom = Color(red: 26 / 255, green: 32 / 255, blue: 41 / 255)
    static let ink = Color(red: 242 / 255, green: 244 / 255, blue: 247 / 255)
    static let duration = Color(red: 207 / 255, green: 212 / 255, blue: 220 / 255)
    static let muted = Color(red: 139 / 255, green: 147 / 255, blue: 161 / 255)
}

private struct PickerGridWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
