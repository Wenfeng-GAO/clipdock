import Foundation

struct VideoAssetSummary: Identifiable, Hashable {
    let id: String
    let creationDate: Date
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int

    var resolutionText: String {
        "\(pixelWidth)x\(pixelHeight)"
    }
}
