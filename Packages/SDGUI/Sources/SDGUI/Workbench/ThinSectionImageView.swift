// ThinSectionImageView.swift
// SDGUI · Workbench
//
// Renders a single thin-section photo. Phase 2 Beta: f.shera's research
// lab has not yet provided real photos, so every record routes through
// `PlaceholderThinSectionView` — a procedural SwiftUI view that draws a
// fake thin-section look (polygonal "crystals" over a tinted background)
// using the photo id as the random seed for a deterministic result.
//
// Phase 3 will extend this file with an `Image(_:bundle:)` branch that
// tries to load a real file matching `photo.id` from
// `Resources/Geology/ThinSections/`, falling back to the procedural
// placeholder when the file is absent. The call site stays
// `ThinSectionImageView(photo: ...)`.
//
// ADR-0001 §"View": purely presentational. Takes a value-typed record,
// reads zero observable state, mutates nothing.

import SwiftUI
import SDGGameplay

/// Display a single thin-section photo (Phase 2 Beta: always a
/// procedural placeholder).
///
/// ### Visual contract
/// * The view fills the square frame it is given (caller-sized). It
///   does NOT hard-code its own size so the parent Microscope view
///   controls the display area.
/// * The photo id seeds the placeholder's random generator so the
///   same `id` always produces the same picture — important for
///   feeling like a real thin section rather than a shimmering random
///   gradient.
/// * Caption rendering is the caller's responsibility.
public struct ThinSectionImageView: View {

    /// The photo record to render. Immutable — callers pass a fresh
    /// record when the selection changes.
    public let photo: ThinSectionPhoto

    /// Memberwise initializer.
    /// - Parameter photo: The record to render.
    public init(photo: ThinSectionPhoto) {
        self.photo = photo
    }

    public var body: some View {
        // Phase 2 Beta: every record routes through the procedural
        // placeholder. Phase 3 will `if let image = UIImage(named: ...)`
        // here.
        PlaceholderThinSectionView(seed: photo.id)
    }
}

/// Procedural SwiftUI thin-section placeholder. Draws a seeded set of
/// polygonal "crystals" on a tinted background to evoke a real thin
/// section without shipping any binary assets. Deterministic for a
/// given seed.
///
/// Kept internal to the module — the only sanctioned entry point is
/// `ThinSectionImageView`, which supplies the seed.
struct PlaceholderThinSectionView: View {

    /// String seed — typically the `ThinSectionPhoto.id`. Hashed once
    /// in `body` to drive both the background hue and the crystal
    /// positions / colors.
    let seed: String

    /// Number of procedural crystals to draw. 28 is dense enough to
    /// look textured at microscope zoom levels but still paints in
    /// under a millisecond on an iPad.
    private let crystalCount = 28

    var body: some View {
        // Hash the seed once per body evaluation. `String.hashValue`
        // varies per-process, but that's fine for a visual placeholder —
        // the same seed within a session always produces the same view,
        // and the player never compares across launches.
        let seedHash = UInt64(bitPattern: Int64(seed.hashValue))
        var rng = SeededGenerator(seed: seedHash)

        let background = placeholderBackground(rng: &rng)
        let crystals = (0..<crystalCount).map { _ in
            Crystal(
                center: UnitPoint(
                    x: Double.random(in: 0.05...0.95, using: &rng),
                    y: Double.random(in: 0.05...0.95, using: &rng)
                ),
                radius: Double.random(in: 0.04...0.14, using: &rng),
                sides: Int.random(in: 5...8, using: &rng),
                rotation: Double.random(in: 0...(.pi * 2), using: &rng),
                color: Color(
                    hue: Double.random(in: 0...1, using: &rng),
                    saturation: Double.random(in: 0.25...0.65, using: &rng),
                    brightness: Double.random(in: 0.45...0.85, using: &rng)
                ),
                opacity: Double.random(in: 0.55...0.9, using: &rng)
            )
        }

        return Canvas { context, size in
            // Background rectangle
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(background))

            // Polygonal "crystals"
            for crystal in crystals {
                let cx = crystal.center.x * size.width
                let cy = crystal.center.y * size.height
                let r = crystal.radius * min(size.width, size.height)
                var path = Path()
                for i in 0..<crystal.sides {
                    let angle = crystal.rotation + (Double(i) * 2 * .pi / Double(crystal.sides))
                    let px = cx + r * cos(angle)
                    let py = cy + r * sin(angle)
                    if i == 0 {
                        path.move(to: CGPoint(x: px, y: py))
                    } else {
                        path.addLine(to: CGPoint(x: px, y: py))
                    }
                }
                path.closeSubpath()
                context.fill(path, with: .color(crystal.color.opacity(crystal.opacity)))
                context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 0.6)
            }
        }
        .background(background)
    }

    /// Tinted base color for the placeholder. Drawn from the seeded
    /// RNG so different layers get visibly different "slide tints".
    private func placeholderBackground(rng: inout SeededGenerator) -> Color {
        Color(
            hue: Double.random(in: 0...1, using: &rng),
            saturation: Double.random(in: 0.10...0.25, using: &rng),
            brightness: Double.random(in: 0.82...0.95, using: &rng)
        )
    }

    /// One procedural crystal.
    private struct Crystal {
        let center: UnitPoint
        let radius: Double
        let sides: Int
        let rotation: Double
        let color: Color
        let opacity: Double
    }
}

/// Tiny deterministic RNG backing `PlaceholderThinSectionView`. Not
/// cryptographically secure; the only design constraint is
/// "same seed ↔ same pixels". SplitMix64 is adequate and fits in a
/// dozen lines — pulling in `GameplayKit` or `SystemRandomNumberGenerator`
/// would either import a heavy framework or lose determinism.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // A zero seed would collapse the stream; nudge it off zero.
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}
