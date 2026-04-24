// AuthStoreTests.swift
// SDGGameplayTests · Auth
//
// Pure state-machine coverage for `AuthStore`. A `FakeAuthProvider`
// replaces the supabase-swift-backed `AuthService` so tests stay
// hermetic.

import XCTest
import Foundation
import SDGCore
@testable import SDGGameplay

@MainActor
final class AuthStoreTests: XCTestCase {

    // MARK: - Fixtures

    private var bus: EventBus!
    private var fake: FakeAuthProvider!
    private var store: AuthStore!

    override func setUp() async throws {
        try await super.setUp()
        bus = EventBus()
        fake = FakeAuthProvider()
        store = AuthStore(eventBus: bus, authService: fake)
    }

    override func tearDown() async throws {
        store = nil
        fake = nil
        bus = nil
        try await super.tearDown()
    }

    // Two yields let MainActor.run continuations in bus handlers land.
    private func drainBus() async {
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Initial state

    func testInitialStateIsSignedOut() {
        XCTAssertNil(store.currentUserId)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.inFlight)
    }

    // MARK: - Sign-in success

    func testSignInWithAppleSuccessSetsUserIdAndPublishes() async {
        let uid = UUID()
        fake.nextSignIn = .success(uid)

        let recorder = EventRecorder<UserSignedIn>()
        let token = await bus.subscribe(UserSignedIn.self) { event in
            await recorder.record(event)
        }

        await store.intent(.signInWithApple(
            idToken: "apple-jwt", rawNonce: "nonce"
        ))
        await drainBus()

        XCTAssertEqual(store.currentUserId, uid)
        XCTAssertNil(store.lastError)
        let received = await recorder.all
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.userId, uid)

        await bus.cancel(token)
    }

    // MARK: - Sign-in failure

    func testSignInWithAppleFailureLeavesStateUnchanged() async {
        fake.nextSignIn = .failure(TestError.network)

        let recorder = EventRecorder<UserSignedIn>()
        let token = await bus.subscribe(UserSignedIn.self) { event in
            await recorder.record(event)
        }

        await store.intent(.signInWithApple(
            idToken: "apple-jwt", rawNonce: "nonce"
        ))
        await drainBus()

        XCTAssertNil(store.currentUserId)
        XCTAssertNotNil(store.lastError)
        let received = await recorder.all
        XCTAssertTrue(received.isEmpty)

        await bus.cancel(token)
    }

    // MARK: - Restore

    func testRestoreOnLaunchPopulatesUserIdWhenSessionExists() async {
        let uid = UUID()
        fake.nextRestore = uid

        await store.intent(.restoreOnLaunch)
        await drainBus()

        XCTAssertEqual(store.currentUserId, uid)
    }

    func testRestoreOnLaunchStaysSignedOutWhenNoSession() async {
        fake.nextRestore = nil

        await store.intent(.restoreOnLaunch)
        await drainBus()

        XCTAssertNil(store.currentUserId)
    }

    // MARK: - Sign-out

    func testSignOutClearsStateAndPublishes() async {
        fake.nextSignIn = .success(UUID())
        await store.intent(.signInWithApple(idToken: "t", rawNonce: "n"))
        XCTAssertNotNil(store.currentUserId)

        let recorder = EventRecorder<UserSignedOut>()
        let token = await bus.subscribe(UserSignedOut.self) { event in
            await recorder.record(event)
        }

        await store.intent(.signOut)
        await drainBus()

        XCTAssertNil(store.currentUserId)
        let received = await recorder.all
        XCTAssertEqual(received.count, 1)

        await bus.cancel(token)
    }

    // MARK: - UI error reporting

    func testReportUIErrorSurfacesInLastError() {
        store.reportUIError("user cancelled Apple sheet")
        XCTAssertEqual(store.lastError, "user cancelled Apple sheet")
    }
}

// MARK: - Fakes

/// Scriptable stub for `AuthProviding`. Tests set `nextRestore` /
/// `nextSignIn` ahead of each call.
///
/// `@unchecked Sendable` because the mutable slots are only touched
/// from the @MainActor test methods; there's no cross-actor access
/// concern in a single-threaded test.
private final class FakeAuthProvider: AuthProviding, @unchecked Sendable {

    var nextRestore: UUID?
    var nextSignIn: Result<UUID, any Error> = .failure(TestError.unconfigured)

    func restoreSession() async throws -> UUID? {
        nextRestore
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws -> UUID {
        try nextSignIn.get()
    }

    func signOut() async throws {}
}

private enum TestError: Error {
    case network
    case unconfigured
}

private actor EventRecorder<E: Sendable> {
    private var events: [E] = []
    func record(_ event: E) { events.append(event) }
    var all: [E] { events }
}
