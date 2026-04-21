import XCTest
@testable import SDGCore

final class SDGCoreTests: XCTestCase {
    func testModuleVersionIsDefined() {
        XCTAssertFalse(SDGCoreModule.version.isEmpty)
    }
}
