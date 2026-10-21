import XCTest
@testable import Glimt

final class OrientationTests: XCTestCase {
    func testRotatingRightFourTimesIsIdentity() {
        for start in 1...8 {
            var orientation = start
            for _ in 0..<4 { orientation = ImageRotator.orientation(after: .rotateRight, from: orientation)! }
            XCTAssertEqual(orientation, start, "orientation \(start)")
        }
    }

    func testEveryTransformIsUndoneByItsInverse() {
        let transforms: [ImageRotator.Transform] = [.rotateRight, .rotateLeft, .rotate180, .flipHorizontal, .flipVertical]
        for start in 1...8 {
            for transform in transforms {
                let applied = ImageRotator.orientation(after: transform, from: start)!
                XCTAssertEqual(ImageRotator.orientation(after: transform.inverse, from: applied), start, "\(transform) from \(start)")
            }
        }
    }

    func testKnownEXIFValues() {
        XCTAssertEqual(ImageRotator.orientation(after: .rotateRight, from: 1), 6)
        XCTAssertEqual(ImageRotator.orientation(after: .rotateLeft, from: 1), 8)
        XCTAssertEqual(ImageRotator.orientation(after: .rotate180, from: 1), 3)
        XCTAssertEqual(ImageRotator.orientation(after: .flipHorizontal, from: 1), 2)
        XCTAssertEqual(ImageRotator.orientation(after: .flipVertical, from: 1), 4)
        XCTAssertEqual(ImageRotator.orientation(after: .rotateRight, from: 2), 7)
    }

    func testUnknownOrientationIsRejected() {
        XCTAssertNil(ImageRotator.orientation(after: .rotateRight, from: 0))
        XCTAssertNil(ImageRotator.orientation(after: .rotateRight, from: 9))
    }
}
