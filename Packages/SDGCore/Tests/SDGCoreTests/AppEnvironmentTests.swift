// AppEnvironmentTests.swift
// SDGCoreTests
//
// Basic smoke coverage for AppEnvironment: default construction works,
// custom injection works, and the module version tag is present.

import XCTest
@testable import SDGCore

final class AppEnvironmentTests: XCTestCase {

    func testModuleVersionIsDefined() {
        XCTAssertFalse(SDGCoreModule.version.isEmpty)
    }

    func testDefaultConstructionYieldsUsableEnvironment() async {
        let env = AppEnvironment()
        // EventBus is usable.
        let count = await env.eventBus.subscriberCount(for: FakeEvent.self)
        XCTAssertEqual(count, 0)
        // Localization is usable (fail-open).
        let key = "ui.button.confirm"
        XCTAssertEqual(env.localization.t(key), key)
    }

    func testCustomInjection() async {
        let sharedBus = EventBus()
        let customLoc = LocalizationService(bundle: .main)
        let env = AppEnvironment(eventBus: sharedBus, localization: customLoc)

        _ = await env.eventBus.subscribe(FakeEvent.self) { _ in }
        let fromContainer = await env.eventBus.subscriberCount(for: FakeEvent.self)
        let fromDirect = await sharedBus.subscriberCount(for: FakeEvent.self)
        XCTAssertEqual(fromContainer, 1)
        XCTAssertEqual(fromDirect, 1,
            "AppEnvironment must hold the same EventBus instance, not a copy")
    }
}

private struct FakeEvent: GameEvent {
    let id: Int
}
