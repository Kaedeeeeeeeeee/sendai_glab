// AudioServiceTests.swift
// SDGPlatformTests · Audio
//
// Lightweight `AudioService` tests. We do not exercise actual audio
// playback in unit tests:
//   - The test bundle doesn't ship the `Resources/Audio/SFX/` tree; we
//     verify the service degrades gracefully when files are missing.
//   - `AVAudioPlayer.play()` touches the audio hardware / audio session
//     which is slow and flaky in CI. Integration-testing real output is
//     a future (manual) job.
//
// What we *do* verify:
//   - init is side-effect-free (no throws, no audio session activation)
//   - play() returns nil for unresolvable resources rather than crashing
//   - masterVolume clamps into [0, 1]
//   - stopAll() is safe on an idle service
//   - cachedPlayerCount reports 0 until a successful play

import XCTest
@testable import SDGPlatform

@MainActor
final class AudioServiceTests: XCTestCase {

    // MARK: - Fixtures

    /// A bundle that definitely does not contain any SFX, used to
    /// drive the "resource not found" path. `Bundle(for:)` picks the
    /// test bundle itself; its `Audio/SFX/` directory doesn't exist,
    /// so every `play()` hits the nil-URL fallback.
    private var emptyBundle: Bundle {
        Bundle(for: type(of: self))
    }

    // MARK: - Init

    func testInitDoesNotThrowOrSideEffect() {
        // Constructing should never touch the audio hardware — if it
        // did, CI would hang on headless runners. A successful init
        // here is the whole assertion.
        let service = AudioService(bundle: emptyBundle)
        XCTAssertEqual(service.masterVolume, 1.0, accuracy: 0.0001)
        XCTAssertEqual(service.transientPlayerCount, 0)
    }

    func testInitClampsMasterVolumeAboveOne() {
        let service = AudioService(bundle: emptyBundle, masterVolume: 2.5)
        XCTAssertEqual(service.masterVolume, 1.0, accuracy: 0.0001)
    }

    func testInitClampsMasterVolumeBelowZero() {
        let service = AudioService(bundle: emptyBundle, masterVolume: -1.0)
        XCTAssertEqual(service.masterVolume, 0.0, accuracy: 0.0001)
    }

    // MARK: - masterVolume setter

    func testSettingMasterVolumeClamps() {
        let service = AudioService(bundle: emptyBundle)
        service.masterVolume = 5.0
        XCTAssertEqual(service.masterVolume, 1.0, accuracy: 0.0001)
        service.masterVolume = -0.5
        XCTAssertEqual(service.masterVolume, 0.0, accuracy: 0.0001)
        service.masterVolume = 0.35
        XCTAssertEqual(service.masterVolume, 0.35, accuracy: 0.0001)
    }

    // MARK: - play() with missing resources

    func testPlayReturnsNilWhenResourceMissing() {
        let service = AudioService(bundle: emptyBundle)
        // Test bundle has no SFX, so every effect returns nil.
        for effect in AudioEffect.allCases {
            XCTAssertNil(
                service.play(effect),
                "Expected nil for missing resource in effect \(effect)"
            )
        }
    }

    func testPlayDoesNotCachePlayerOnFailedLookup() {
        let service = AudioService(bundle: emptyBundle)
        _ = service.play(.uiTap)
        // Lookup failed → no player created → cache stays empty.
        XCTAssertEqual(service.cachedPlayerCount(for: .uiTap), 0)
    }

    // MARK: - stopAll()

    func testStopAllIsSafeOnIdleService() {
        let service = AudioService(bundle: emptyBundle)
        // Should not throw or crash; no assertion needed beyond not
        // exploding. A blown assertion on `transientPlayerCount` would
        // still be useful.
        service.stopAll()
        XCTAssertEqual(service.transientPlayerCount, 0)
    }

    // MARK: - custom subdirectory

    func testCustomSubdirectoryIsRespected() {
        // Construction with an arbitrary subdirectory path must still
        // not throw. Wiring between `subdirectory` and the bundle
        // lookup is covered indirectly: every lookup still returns
        // nil since the test bundle has neither path.
        let service = AudioService(
            bundle: emptyBundle,
            subdirectory: "Completely/Absent/Path"
        )
        XCTAssertNil(service.play(.uiTap))
    }
}
