// SampleIconRenderer.swift
// SDGUI · Samples
//
// Off-screen PNG renderer for `SampleIconView`. Powers the background
// half of the "sample thumbnail" pipeline: the UI can always compose
// `SampleIconView` directly, but persisting the icon as a PNG lets
// other surfaces (Finder-style asset dumps, OS share sheets, debug
// tooling) consume it without rebuilding the SwiftUI view tree.
//
// Pipeline:
//   SampleIconView (SwiftUI)
//     → ImageRenderer (SwiftUI)
//       → CGImage
//         → CFData (via ImageIO, PNG UTI)
//           → on-disk PNG at
//             Application Support/sdg-lab/sample_icons/{sampleId}.png
//
// We use ImageIO's `CGImageDestination` rather than `UIImage.pngData()`
// or `NSImage.tiffRepresentation` so the PNG-encoding path is identical
// across iOS 18 and macOS 15 — important because `swift test` for
// SDGUI runs on macOS in CI.

import Foundation
import SwiftUI
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import SDGGameplay

/// Off-screen PNG renderer + disk cache for sample icons.
///
/// The renderer is MainActor-isolated because `ImageRenderer`'s
/// `cgImage` property is itself MainActor-only (it drives a SwiftUI
/// render pass). Callers that want to hop off the main actor should
/// schedule `await MainActor.run { … }` themselves.
///
/// No instance state is held, so `SampleIconRenderer` is an `enum`
/// with `static` entry points — matching the `SampleEntity` style in
/// the gameplay package. This avoids both a singleton (ADR-0001,
/// AGENTS.md Rule 2) and a meaningless initialiser.
@MainActor
public enum SampleIconRenderer {

    // MARK: - Errors

    /// Errors the renderer can raise when writing to disk.
    ///
    /// `renderPNGData` returns `nil` on failure (the "get me a blob"
    /// path is forgiving), but `renderAndCache` throws because
    /// callers who asked for a URL will typically want to distinguish
    /// "couldn't render" from "couldn't write" — e.g. to retry on a
    /// transient disk error without re-running the expensive render.
    public enum RenderError: Error, Equatable {
        /// `ImageRenderer` returned `nil` for `cgImage`. Most common
        /// cause is a zero-sized proposed frame; on CI it can also mean
        /// SwiftUI couldn't start a render pass (e.g. missing display
        /// environment in headless mode).
        case renderFailed

        /// ImageIO refused to create a PNG destination or finalise it.
        /// Wrapped `reason` is a free-form human-readable string —
        /// `equatable` ignores the reason so tests can assert the case
        /// without pinning exact wording.
        case pngEncodingFailed(reason: String)

        /// `FileManager` couldn't create the icons cache directory or
        /// write the file. Wrapped `underlying` is the original error
        /// for diagnostics; `equatable` skips it for the same reason
        /// as `pngEncodingFailed`.
        case fileSystemFailed(underlying: Error)

        public static func == (lhs: RenderError, rhs: RenderError) -> Bool {
            switch (lhs, rhs) {
            case (.renderFailed, .renderFailed): return true
            case (.pngEncodingFailed, .pngEncodingFailed): return true
            case (.fileSystemFailed, .fileSystemFailed): return true
            default: return false
            }
        }
    }

    // MARK: - Constants

    /// Default icon size in points. 256 × 256 covers both a standard
    /// inventory-grid cell (64 pt × 4x Retina) and a HUD badge (32 pt
    /// × 8x) without re-encoding, which is what this renderer is for.
    public static let defaultSize = CGSize(width: 256, height: 256)

    /// Default pixel scale. `2.0` pairs with `defaultSize` to produce
    /// a 512 × 512 raster — enough fidelity on today's Retina iPads
    /// without blowing up on-disk size. (A 256×256 24-bit PNG at
    /// scale 2 is typically ~2–4 KB of solid-colour bands.)
    public static let defaultScale: CGFloat = 2.0

    // MARK: - Public API

    /// Render a sample icon in-memory and return the PNG bytes.
    ///
    /// - Parameters:
    ///   - sample: The sample to render. Passed straight to
    ///     `SampleIconView(sample:)`.
    ///   - size: Canvas size in points. Default 256 × 256.
    ///   - scale: Raster scale. Default 2.0 (Retina).
    /// - Returns: PNG bytes, or `nil` if either the SwiftUI render or
    ///   PNG encoding failed. Use `renderAndCache(for:)` when the
    ///   failure reason matters.
    public static func renderPNGData(
        for sample: SampleItem,
        size: CGSize = defaultSize,
        scale: CGFloat = defaultScale
    ) -> Data? {
        guard let cgImage = makeCGImage(for: sample, size: size, scale: scale) else {
            return nil
        }
        return pngData(from: cgImage)
    }

    /// Render a sample icon and write it to the on-disk cache.
    ///
    /// The cache lives at
    /// `Application Support/sdg-lab/sample_icons/{sampleId}.png`.
    /// The directory is created on demand; repeated calls simply
    /// overwrite the existing file (no change detection — the payload
    /// is tiny and overwrites are cheaper than hashing).
    ///
    /// - Parameters:
    ///   - sample: The sample to render. Filename derives from
    ///     `sample.id.uuidString`.
    ///   - size: Canvas size in points. Default 256 × 256.
    ///   - scale: Raster scale. Default 2.0 (Retina).
    /// - Returns: File URL of the cached PNG.
    /// - Throws: `RenderError.renderFailed` when SwiftUI could not
    ///   produce a raster, `RenderError.pngEncodingFailed` when
    ///   ImageIO refused the encode, or
    ///   `RenderError.fileSystemFailed` when the directory or file
    ///   write failed.
    @discardableResult
    public static func renderAndCache(
        for sample: SampleItem,
        size: CGSize = defaultSize,
        scale: CGFloat = defaultScale
    ) throws -> URL {
        guard let cgImage = makeCGImage(for: sample, size: size, scale: scale) else {
            throw RenderError.renderFailed
        }
        guard let data = pngData(from: cgImage) else {
            throw RenderError.pngEncodingFailed(
                reason: "CGImageDestination finalize failed"
            )
        }

        let directory: URL
        do {
            directory = try ensureCacheDirectory()
        } catch {
            throw RenderError.fileSystemFailed(underlying: error)
        }

        let fileURL = directory.appendingPathComponent(
            "\(sample.id.uuidString).png",
            isDirectory: false
        )

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw RenderError.fileSystemFailed(underlying: error)
        }

        return fileURL
    }

    /// URL of a previously cached icon, or `nil` if none exists.
    ///
    /// Does not render; pure filesystem lookup. Callers typically
    /// bind this into `Image(contentsOfFile:)` / `NSImage(contentsOf:)`
    /// for "use cache, else render on miss" flows.
    ///
    /// - Parameter sampleId: The `SampleItem.id` of interest.
    /// - Returns: The cache URL when the file exists, else `nil`.
    public static func cachedIconURL(for sampleId: UUID) -> URL? {
        // `cacheDirectoryURL` never throws (read-only path math), so
        // no error-handling ceremony; just verify existence.
        guard let directory = cacheDirectoryURL() else { return nil }
        let fileURL = directory.appendingPathComponent(
            "\(sampleId.uuidString).png",
            isDirectory: false
        )
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Delete the cached icon for a sample.
    ///
    /// No-op when the file is already missing — the goal is "after
    /// this call the icon is gone", not strict existence checking.
    ///
    /// - Parameter sampleId: The `SampleItem.id` whose icon to delete.
    /// - Throws: `RenderError.fileSystemFailed` when the deletion
    ///   fails for reasons other than "file already gone".
    public static func removeCache(for sampleId: UUID) throws {
        guard let url = cachedIconURL(for: sampleId) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw RenderError.fileSystemFailed(underlying: error)
        }
    }

    // MARK: - Internal helpers (visible to tests)

    /// Compute the on-disk cache directory URL without creating it.
    ///
    /// Returns `nil` when the platform does not expose an Application
    /// Support directory (extremely rare — the OS guarantees one on
    /// both iOS and macOS, but the API is nullable so we honour it).
    internal static func cacheDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("sdg-lab", isDirectory: true)
            .appendingPathComponent("sample_icons", isDirectory: true)
    }

    /// Ensure the cache directory exists and return its URL.
    ///
    /// `FileManager.createDirectory(..., withIntermediateDirectories:
    /// true)` is a no-op when the directory already exists, so this
    /// is safe to call on every write.
    internal static func ensureCacheDirectory() throws -> URL {
        guard let url = cacheDirectoryURL() else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    // MARK: - Private

    /// Drive `ImageRenderer` for the given sample and return a
    /// `CGImage`, or `nil` if SwiftUI failed to rasterise.
    ///
    /// Kept separate from the PNG encoding step so tests that only
    /// care about "did a raster come out" don't pay for ImageIO.
    private static func makeCGImage(
        for sample: SampleItem,
        size: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let view = SampleIconView(sample: sample)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// Encode a `CGImage` as PNG bytes via ImageIO.
    ///
    /// Returns `nil` when CGImageDestination creation or finalisation
    /// fails; at the call sites we translate that into the richer
    /// `RenderError.pngEncodingFailed` when the caller cares.
    private static func pngData(from cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.png.identifier as CFString
        #else
        type = "public.png" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, type, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
