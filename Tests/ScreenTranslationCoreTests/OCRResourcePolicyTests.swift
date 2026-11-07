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
