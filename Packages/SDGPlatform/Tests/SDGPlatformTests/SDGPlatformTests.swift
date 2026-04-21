import XCTest
@testable import SDGPlatform

final class SDGPlatformTests: XCTestCase {
    func testModuleVersionIsDefined() {
        XCTAssertFalse(SDGPlatformModule.version.isEmpty)
    }
}
