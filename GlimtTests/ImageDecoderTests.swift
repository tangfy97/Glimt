import XCTest
@testable import Glimt

final class ImageDecoderTests: XCTestCase {
    private let screen = CGSize(width: 1000, height: 1000)

    func testFullResolutionIsCappedByPixelBudgetAndTextureSize() {
        XCTAssertEqual(ImageDecoder.fullLongestSide(for: CGSize(width: 6000, height: 4000)), 6000)
        let huge = ImageDecoder.fullLongestSide(for: CGSize(width: 20000, height: 15000))
        XCTAssertLessThanOrEqual(CGFloat(huge * huge) * 0.75, ImageDecoder.fullPixelBudget * 1.01)
        XCTAssertLessThanOrEqual(ImageDecoder.fullLongestSide(for: CGSize(width: 30000, height: 1000)), Int(ImageDecoder.maxTextureSide))
    }

    func testEXIFOrientationSwapsTheSourceSize() throws {
        let url = try Fixtures.image(at: Fixtures.temporaryFolder().appendingPathComponent("rotated.jpg"), width: 80, height: 40, orientation: 6)
        let image = try XCTUnwrap(ImageDecoder.decode(url, level: .preview, screenPixels: screen))
        XCTAssertEqual(image.sourceSize, CGSize(width: 40, height: 80))
        XCTAssertEqual(image.surface.width, 40)
        XCTAssertEqual(image.surface.height, 80)
    }

    func testPreviewFitsTheScreenWithoutUpscaling() throws {
        let folder = try Fixtures.temporaryFolder()
        let big = try XCTUnwrap(ImageDecoder.decode(try Fixtures.image(at: folder.appendingPathComponent("big.jpg"), width: 3000, height: 2000),
                                                    level: .preview, screenPixels: screen))
        XCTAssertEqual(big.longestSide, 1000)
        let small = try XCTUnwrap(ImageDecoder.decode(try Fixtures.image(at: folder.appendingPathComponent("small.jpg"), width: 300, height: 200),
                                                      level: .preview, screenPixels: screen))
        XCTAssertEqual(small.longestSide, 300)
    }

    func testQuickLevelOnlyUsesAnEmbeddedThumbnail() throws {
        let url = try Fixtures.image(at: Fixtures.temporaryFolder().appendingPathComponent("plain.jpg"))
        XCTAssertNil(ImageDecoder.decode(url, level: .quick, screenPixels: screen), "no embedded thumbnail, so no quick rung")
    }

    func testUnreadableFileDecodesToNil() throws {
        let url = try Fixtures.temporaryFolder().appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: url)
        XCTAssertNil(ImageDecoder.decode(url, level: .preview, screenPixels: screen))
    }
}
