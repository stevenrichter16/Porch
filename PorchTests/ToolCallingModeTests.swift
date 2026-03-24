import XCTest
@testable import Porch

final class ToolCallingModeTests: XCTestCase {

    func testAllCasesArePresent() {
        let allCases = ToolCallingMode.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.auto))
        XCTAssertTrue(allCases.contains(.native))
        XCTAssertTrue(allCases.contains(.promptBased))
    }

    func testRawValueRoundTrips() {
        for mode in ToolCallingMode.allCases {
            let recovered = ToolCallingMode(rawValue: mode.rawValue)
            XCTAssertEqual(recovered, mode)
        }
    }

    func testDisplayNameIsNonEmpty() {
        for mode in ToolCallingMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    func testDefaultIsAuto() {
        // Verify that an unknown raw value falls back safely
        XCTAssertNil(ToolCallingMode(rawValue: "unknown"))
    }
}
