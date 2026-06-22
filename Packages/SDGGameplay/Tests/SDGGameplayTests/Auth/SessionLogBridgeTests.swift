// SessionLogBridgeTests.swift
// SDGGameplayTests · Auth
//
// Exercises the AppSessionStarted → logSession plumbing with a
// recording telemetry writer.

import XCTest
import Foundation
import SDGCore
@testable import SDGGameplay

@MainActor
final class SessionLogBridgeTests: XCTestCase {

    // MARK: - Fixtures

    private var bus: EventBus!

    override func setUp() async throws {
        try await super.setUp()
        bus = EventBus()
    }

    override func tearDown() async throws {
        bus = nil
        try await super.tearDown()
    }

    // Six yields to cover MainActor.run + inner Task { try await ... }
    // which crosses two continuation hops before hitting the recorder.
    private func drain() async {
        for _ in 0..<6 { await Task.yield() }
    }

    // MARK: - Subscription count

    func testStartInstallsOneSubscription() async {
        let store = AuthStore(eventBus: bus, authService: NoopAuthProvider())
        let bridge = SessionLogBridge(
            eventBus: bus,
            authStore: store,
            telemetry: RecordingTelemetryWriter()
        )
        await bridge.start()
        XCTAssertEqual(bridge.subscriptionCount, 1)
        await bridge.stop()
    }

    // MARK: - AppSessionStarted with signed-in user

    func testAppSessionStartedLogsWhenUserIsSignedIn() async {
        let uid = UUID()
        let fake = FakeAuthProvider(sessionToReturn: uid)
        let store = AuthStore(eventBus: bus, authService: fake)

        // Sign in FIRST, before the bridge exists. The
        // `UserSignedIn` event that fires during this sign-in goes
        // to an empty bus (no subscribers yet), so it doesn't
        // pollute the recorder.
        await store.intent(.signInWithApple(idToken: "t", rawNonce: "n"))
        await drain()
        XCTAssertEqual(store.currentUserId, uid)

        let telemetry = RecordingTelemetryWriter()
        let bridge = SessionLogBridge(
            eventBus: bus, authStore: store, telemetry: telemetry
        )
        await bridge.start()

        await bus.publish(AppSessionStarted(
            at: Date(timeIntervalSince1970: 42),
            osVersion: "18.3",
            locale: "ja-JP"
        ))
        await drain()

        let rows = await telemetry.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.userId, uid)
        XCTAssertEqual(rows.first?.osVersion, "18.3")
        XCTAssertEqual(rows.first?.locale, "ja-JP")

        await bridge.stop()
    }

    // MARK: - AppSessionStarted with no user

    func testAppSessionStartedDroppedWhenNotSignedIn() async {
        let store = AuthStore(eventBus: bus, authService: NoopAuthProvider())
        let telemetry = RecordingTelemetryWriter()
        let bridge = SessionLogBridge(
            eventBus: bus, authStore: store, telemetry: telemetry
        )
        await bridge.start()

        await bus.publish(AppSessionStarted(
            at: Date(),
            osVersion: "18.3",
            locale: "ja-JP"
        ))
        await drain()

        let rows = await telemetry.rows
        XCTAssertTrue(rows.isEmpty)

        await bridge.stop()
    }

}

// MARK: - Fakes

private actor RecordingTelemetryWriter: TelemetryWriting {
    struct Row: Equatable {
        let userId: UUID
        let at: Date
        let osVersion: String
        let locale: String
    }

    private(set) var rows: [Row] = []

    func logSession(
        userId: UUID,
        at: Date,
        osVersion: String,
        locale: String
    ) async throws {
        rows.append(Row(
            userId: userId, at: at,
            osVersion: osVersion, locale: locale
        ))
    }
}

private final class FakeAuthProvider: AuthProviding, @unchecked Sendable {
    let sessionToReturn: UUID

    init(sessionToReturn: UUID) {
        self.sessionToReturn = sessionToReturn
    }

    func restoreSession() async throws -> UUID? { sessionToReturn }
    func signInWithApple(idToken: String, rawNonce: String) async throws -> UUID {
        sessionToReturn
    }
    func signOut() async throws {}
}
