// LocationComponentTests.swift
// SDGGameplayTests · World
//
// Phase 9 Part F — pure-data contracts for `LocationComponent` +
// `LocationKind`. We do not build a scene here; the tests assert
// Codable round-tripping, Equatable semantics, and the constructor
// passing the kind through unchanged. These guarantees matter because
// the Store + Component rely on `LocationKind.Equatable` to gate
// transitions ("already at target? do nothing"), and future
// persistence will depend on the Codable shape.

import XCTest
@testable import SDGGameplay

final class LocationComponentTests: XCTestCase {

    // MARK: - LocationKind equality

    func testOutdoorEqualsOutdoor() {
        XCTAssertEqual(LocationKind.outdoor, LocationKind.outdoor)
    }

    func testIndoorEqualsSameSceneId() {
        XCTAssertEqual(
            LocationKind.indoor(sceneId: "lab"),
            LocationKind.indoor(sceneId: "lab")
        )
    }

    func testIndoorDiffersBySceneId() {
        XCTAssertNotEqual(
            LocationKind.indoor(sceneId: "lab"),
            LocationKind.indoor(sceneId: "storeroom")
        )
    }

    func testOutdoorDiffersFromIndoor() {
        XCTAssertNotEqual(
            LocationKind.outdoor,
            LocationKind.indoor(sceneId: "lab")
        )
    }

    // MARK: - Codable round-trip

    func testLocationKindOutdoorRoundTrip() throws {
        let original = LocationKind.outdoor
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LocationKind.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLocationKindIndoorRoundTrip() throws {
        let original = LocationKind.indoor(sceneId: "lab")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LocationKind.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - LocationComponent construction

    func testComponentStoresKindUnchanged() {
        let outdoor = LocationComponent(.outdoor)
        XCTAssertEqual(outdoor.kind, .outdoor)

        let indoor = LocationComponent(.indoor(sceneId: "lab"))
        XCTAssertEqual(indoor.kind, .indoor(sceneId: "lab"))
    }

    func testComponentEquatable() {
        XCTAssertEqual(
            LocationComponent(.outdoor),
            LocationComponent(.outdoor)
        )
        XCTAssertNotEqual(
            LocationComponent(.outdoor),
            LocationComponent(.indoor(sceneId: "lab"))
        )
    }
}
