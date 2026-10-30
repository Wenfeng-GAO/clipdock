import SwiftUI
import UIKit
import XCTest
@testable import ClipDock

@MainActor
final class VideoPickerThumbnailScrimTests: XCTestCase {
    func testSharedScrimAndWhiteLabelsOverWhiteAndBlackPosters() throws {
        for (name, color) in [("white", UIColor.white), ("black", UIColor.black)] {
            let poster = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            }
            let renderer = ImageRenderer(content:
                Image(uiImage: poster)
                    .resizable()
                    .frame(width: 160, height: 160)
                    .overlay(alignment: .bottom) {
                        VideoPickerThumbnailInfo(leadingText: "☁︎ 1:23", sizeText: "128 MB")
                    }
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 160, height: 160, bitsPerComponent: 8,
                bytesPerRow: 160 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // Normalize to RGBA bytes; the first bitmap row is the image's top row.
            context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 160))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            func brightness(_ x: Int, _ y: Int) -> Double {
                let offset = (y * 160 + x) * 4
                return Double(Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / (3 * 255)
            }
            if name == "white" {
                XCTAssertGreaterThan(brightness(80, 127), 0.98, "Poster above the 32pt scrim stays white")
                XCTAssertGreaterThan(brightness(80, 130), brightness(80, 145))
                for x in [2, 80, 157] {
                    XCTAssertLessThan(brightness(x, 158), 0.8, "Shared band darkens the full width")
                    XCTAssertGreaterThan(brightness(x, 158), 0.35, "Scrim remains translucent")
                }
            } else {
                XCTAssertLessThan(brightness(80, 158), 0.02, "Black poster stays black")
            }
            for x in Array(0..<8) + Array(152..<160) {
                for y in 140..<156 {
                    XCTAssertEqual(brightness(x, y), brightness(80, y), accuracy: 0.01,
                                   "Both labels keep at least 8pt horizontal inset")
                }
            }
            for columns in [8..<64, 96..<152] {
                let whiteTextPixels = (143..<156).reduce(0) { count, y in
                    // Allow antialiasing of the small semibold glyphs at 1x.
                    count + columns.filter { brightness($0, y) > 0.9 }.count
                }
                XCTAssertGreaterThan(whiteTextPixels, 15, "Both labels stay white on the \(name) poster")
            }
        }
    }
}
