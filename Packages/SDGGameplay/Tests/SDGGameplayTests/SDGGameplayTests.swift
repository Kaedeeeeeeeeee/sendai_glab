import XCTest
@testable import SDGGameplay

final class SDGGameplayTests: XCTestCase {
    /// SDGGameplay must link against a matching SDGCore build. This assertion
    /// is intentionally hard-coded rather than compared to
    /// `SDGCoreModule.version` directly so a stale checkout of either package
    /// surfaces as a test failure, not as a silently-passing tautology.
    func testGameplayLinksCore() {
        XCTAssertEqual(SDGGameplayModule.coreVersion, "0.1.0")
    }
}
