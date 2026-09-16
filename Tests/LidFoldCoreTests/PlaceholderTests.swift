import XCTest
@testable import LidFoldCore

// M2 起放狀態機的 CSV 回放測試。M0 先確保 target 能編。
final class PlaceholderTests: XCTestCase {
    func testDegreesPerRawUnitIsPositive() {
        XCTAssertGreaterThan(LidSensor.degreesPerRawUnit, 0)
    }
}
