import XCTest
@testable import ScreenTranslationCore

final class OCRResourcePolicyTests: XCTestCase {
    func testDeviceReportSelectsSmallerWindowsBeforeStartingAnotherModel() {
        let policy = OCRResourcePolicy(memoryLimited: true, availableBytes: 31_963_152, footprintBytes: 198_723_568)
        XCTAssertTrue(policy.constrained)
        XCTAssertTrue(policy.prefersCPU)
        XCTAssertEqual(policy.tileDimension, 1024)
        XCTAssertTrue(OCRResourcePolicy(memoryLimited: true, availableBytes: 80 * 1_024 * 1_024).constrained)
        XCTAssertFalse(OCRResourcePolicy(memoryLimited: true).constrained, "An unknown simulator budget is not zero free RAM")
    }

    func testAcceleratedAndConcurrentRecognitionNeedsMeasuredHeadroom() {
        // The 1.10 device record: 42 MB available at the first document tile.
        let tight = OCRResourcePolicy(memoryLimited: true, availableBytes: 42_743_728, footprintBytes: 187_942_992)
        XCTAssertTrue(tight.prefersCPU); XCTAssertFalse(tight.allowsConcurrentPasses)
        let unknown = OCRResourcePolicy(memoryLimited: true)
        XCTAssertTrue(unknown.prefersCPU, "An unknown budget must keep the conservative path")
        let roomy = OCRResourcePolicy(memoryLimited: true, availableBytes: 180 * 1_024 * 1_024, footprintBytes: 60 * 1_024 * 1_024)
        XCTAssertFalse(roomy.prefersCPU); XCTAssertTrue(roomy.allowsConcurrentPasses)
        XCTAssertEqual(roomy.tileDimension, 1536)
        let warned = OCRResourcePolicy(memoryLimited: true, recentWarning: true, availableBytes: 300 * 1_024 * 1_024)
        XCTAssertTrue(warned.prefersCPU, "A recent memory warning always selects the conservative path")
        let app = OCRResourcePolicy(memoryLimited: false)
        XCTAssertFalse(app.prefersCPU); XCTAssertTrue(app.allowsConcurrentPasses)
    }

    func testAppAlsoReadsLargePagesInSourceResolutionTiles() {
        let app = OCRResourcePolicy(memoryLimited: false)
        XCTAssertEqual(app.tileDimension, 1536)
        XCTAssertEqual(app.regions(for: CGSize(width: 1179, height: 2556)).count, 2, "Small print needs source-resolution tiles")
        XCTAssertEqual(app.regions(for: CGSize(width: 900, height: 1200)), [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    func testOverlappingWindowsCoverEverySourcePixelAndBoundTheWorkingArea() {
        for constrained in [false, true] {
            let policy = OCRResourcePolicy(memoryLimited: true, recentWarning: constrained)
            for size in [CGSize(width: 1260, height: 2736), CGSize(width: 2560, height: 2560), CGSize(width: 3200, height: 1800)] {
                let tiles = policy.regions(for: size)
                XCTAssertLessThanOrEqual(tiles.count, 12)
                for tile in tiles {
                    XCTAssertLessThanOrEqual(tile.width * size.width, CGFloat(policy.tileDimension) + 0.001)
                    XCTAssertLessThanOrEqual(tile.height * size.height, CGFloat(policy.tileDimension) + 0.001)
                }
                for y in stride(from: 0.001, to: 1.0, by: 0.02) {
                    for x in stride(from: 0.001, to: 1.0, by: 0.02) {
                        XCTAssertTrue(tiles.contains { $0.contains(CGPoint(x: x, y: y)) })
                    }
                }
                XCTAssertTrue(tiles.enumerated().allSatisfy { i, rect in
                    tiles.enumerated().contains { j, other in i != j && rect.intersects(other) }
                })
            }
        }
    }
}
