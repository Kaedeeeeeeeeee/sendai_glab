import XCTest
@testable import SDGUI

final class SDGUITests: XCTestCase {
    func testModuleVersionIsDefined() {
        XCTAssertFalse(SDGUIModule.version.isEmpty)
    }
}
