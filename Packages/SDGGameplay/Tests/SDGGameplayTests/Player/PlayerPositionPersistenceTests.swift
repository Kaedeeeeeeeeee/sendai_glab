// PlayerPositionPersistenceTests.swift
// SDGGameplayTests · Player
//
// Exercises `PlayerPositionPersistence` save/load round-trips. No
// Store integration because player pose is not owned by a Store —
// the live truth is the RealityKit entity and `AppLaunchCoordinator`
// drives the save/load directly.

import XCTest
import Foundation
@testable import SDGGameplay

final class PlayerPositionPersistenceTests: XCTestCase {

    private func makeScopedDefaults(
        _ label: String = #function
    ) throws -> (UserDefaults, String) {
        let suiteName = "sdg.playerposition.tests.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create scoped UserDefaults suite")
            throw XCTSkip("UserDefaults(suiteName:) returned nil")
        }
        return (defaults, suiteName)
    }

    // MARK: - inMemory backend

    func testInMemoryRoundTripPreservesPosition() throws {
        let persistence = PlayerPositionPersistence.inMemory
        let snapshot = PlayerPositionPersistence.Snapshot(
            position: SIMD3<Float>(42, 7, -13),
            yawRadians: .pi / 3
        )

        try persistence.save(snapshot)
        let loaded = try persistence.load()

        XCTAssertEqual(loaded, snapshot)
    }

    func testInMemoryLoadOnEmptyReturnsNil() throws {
        let persistence = PlayerPositionPersistence.inMemory
        let loaded = try persistence.load()
        XCTAssertNil(loaded,
                     "first launch must signal 'no saved pose' with nil")
    }

    func testSchemaKeyIsVersioned() {
        XCTAssertEqual(
            PlayerPositionPersistence.schemaKey,
            "sdg.playerposition.v1"
        )
    }

    // MARK: - UserDefaults backend

    func testUserDefaultsRoundTripPreservesPosition() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = PlayerPositionPersistence.userDefaults(defaults)
        let snapshot = PlayerPositionPersistence.Snapshot(
            position: SIMD3<Float>(-5, 1.6, 12.5),
            yawRadians: -.pi / 4
        )

        try persistence.save(snapshot)
        let loaded = try persistence.load()

        XCTAssertEqual(loaded, snapshot)
    }

    func testUserDefaultsSaveOverwritesPriorPose() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = PlayerPositionPersistence.userDefaults(defaults)

        try persistence.save(.init(
            position: SIMD3<Float>(1, 0, 0), yawRadians: 0
        ))
        try persistence.save(.init(
            position: SIMD3<Float>(0, 0, 1), yawRadians: .pi
        ))

        let loaded = try persistence.load()
        XCTAssertEqual(loaded?.position, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(loaded?.yawRadians, .pi)
    }

    func testUserDefaultsLoadThrowsOnCorruptPayload() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            Data([0xDE, 0xAD, 0xBE, 0xEF]),
            forKey: PlayerPositionPersistence.schemaKey
        )
        let persistence = PlayerPositionPersistence.userDefaults(defaults)

        XCTAssertThrowsError(try persistence.load()) { error in
            XCTAssertTrue(error is DecodingError,
                          "expected DecodingError, got \(error)")
        }
    }
}
