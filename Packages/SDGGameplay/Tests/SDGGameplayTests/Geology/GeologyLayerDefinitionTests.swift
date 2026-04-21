// GeologyLayerDefinitionTests.swift
// Tests for the JSON data contract. Scene-building behaviour is
// covered separately by `GeologySceneBuilderTests`.

import XCTest
@testable import SDGGameplay

final class GeologyLayerDefinitionTests: XCTestCase {

    // MARK: - Round-trip

    /// A JSON encode → decode cycle must preserve every declared
    /// field. If this ever breaks, the legacy `test_outcrop.json`
    /// silently loses data on load, which would be very hard to
    /// debug from runtime artefacts alone.
    func testDefinitionCodableRoundTrip() throws {
        let original = GeologyLayerDefinition(
            id: "aobayama.topsoil",
            nameKey: "geology.layer.topsoil.name",
            type: .soil,
            colorHex: "#6B4226",
            thickness: 0.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            GeologyLayerDefinition.self,
            from: data
        )

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.nameKey, original.nameKey)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.colorHex, original.colorHex)
        XCTAssertEqual(decoded.thickness, original.thickness)
    }

    /// The config bundle (which owns `origin: SIMD3<Float>` — the
    /// trickiest field to Codable-serialise) must also round-trip.
    func testOutcropConfigCodableRoundTrip() throws {
        let original = TestOutcropConfig(
            name: "AobayamaTestOutcrop",
            origin: SIMD3<Float>(1, 2, 3),
            layers: [
                GeologyLayerDefinition(
                    id: "l1",
                    nameKey: "k1",
                    type: .sedimentary,
                    colorHex: "#C2B280",
                    thickness: 1.5
                ),
                GeologyLayerDefinition(
                    id: "l2",
                    nameKey: "k2",
                    type: .metamorphic,
                    colorHex: "#4A4E69",
                    thickness: 3.0
                )
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            TestOutcropConfig.self,
            from: data
        )

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.origin, original.origin)
        XCTAssertEqual(decoded.layers.count, original.layers.count)
        XCTAssertEqual(decoded.layers[0].id, "l1")
        XCTAssertEqual(decoded.layers[1].type, .metamorphic)
    }

    // MARK: - Hex parsing

    /// Canonical `"#RRGGBB"` shape must decode to correct 0…1 values.
    /// 0xFF maps to 1.0 exactly; the test uses mid-range bytes so a
    /// rounding regression would show as a non-zero delta.
    func testParseHexValid() throws {
        let rgb = try GeologySceneBuilder.parseHex("#804020")
        XCTAssertEqual(rgb.x, Float(0x80) / 255.0, accuracy: 1e-6)
        XCTAssertEqual(rgb.y, Float(0x40) / 255.0, accuracy: 1e-6)
        XCTAssertEqual(rgb.z, Float(0x20) / 255.0, accuracy: 1e-6)
    }

    /// Leading `#` must be optional; some upstream tools (and
    /// hand-written JSON) omit it.
    func testParseHexWithoutHashPrefix() throws {
        let rgb = try GeologySceneBuilder.parseHex("FFFFFF")
        XCTAssertEqual(rgb, SIMD3<Float>(1, 1, 1))
    }

    /// Wrong-length literals must throw `.invalidColorHex`. We also
    /// assert the associated value so future refactors can't silently
    /// drop the context from the error.
    func testParseHexRejectsShortString() {
        XCTAssertThrowsError(try GeologySceneBuilder.parseHex("#ABC")) { err in
            guard case GeologySceneBuilderError.invalidColorHex(let bad) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(bad, "#ABC")
        }
    }

    /// Non-hex characters must also throw — `UInt32(_, radix: 16)`
    /// returns nil rather than throwing, so this guards the fallback
    /// in `parseHex`.
    func testParseHexRejectsNonHex() {
        XCTAssertThrowsError(try GeologySceneBuilder.parseHex("#ZZZZZZ")) { err in
            guard case GeologySceneBuilderError.invalidColorHex = err else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    // MARK: - LayerType

    /// LayerType is `Codable` via raw values; confirm the strings
    /// we ship in JSON actually map back to cases. If someone
    /// renames a case, this catches it before runtime.
    func testLayerTypeCodableRawValues() throws {
        for type in LayerType.allCases {
            let json = "\"\(type.rawValue)\"".data(using: .utf8)!
            let decoded = try JSONDecoder().decode(LayerType.self, from: json)
            XCTAssertEqual(decoded, type)
        }
    }

    /// Every LayerType must expose a plausible (positive, realistic)
    /// default density — future sample-mass maths divides by it.
    func testLayerTypeDefaultDensityPlausible() {
        for type in LayerType.allCases {
            XCTAssertGreaterThan(type.defaultDensity, 1.0)
            XCTAssertLessThan(type.defaultDensity, 5.0)
        }
    }
}
