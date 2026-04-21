import XCTest
@testable import SDGGameplay

final class SDGGameplayTests: XCTestCase {
    func testGameplayLinksCore() {
        XCTAssertEqual(SDGGameplayModule.coreVersion, "0.0.0")
    }
}
