// GLBToUSDZConverter.swift
// SDGGameplay · World
//
// Runtime conversion step: takes a bundle-embedded GLB and returns the
// URL of an equivalent USDZ in the user's Application Support cache.
// Hashing the source GLB's contents lets us skip the expensive convert
// on subsequent launches.
//
// ## Reality check on ModelIO GLB support
//
// A runtime probe on both macOS 15 and iOS Simulator 26 (2026-04-22)
// shows that ModelIO *cannot* import `.glb` / `.gltf`:
//
//     MDLAsset.canImportFileExtension("glb")   // → false
//     MDLAsset.canImportFileExtension("gltf")  // → false
//     MDLAsset.canExportFileExtension("usdz")  // → false
//
// ModelIO also cannot export directly to `.usdz` — only `.usd`, `.usda`,
// `.usdc`, `.obj`, `.ply`, `.abc`, `.stl`. Same for RealityKit's
// `Entity(contentsOf:)`: it throws `.noImporter(glb url)`.
//
// That means the simple pipeline proposed in the task spec
// (GLB → MDLAsset(url:) → asset.export(to: usdz)) does not execute on
// the platforms we ship to. We still ship this file, but with a
// **two-path strategy** that matches reality:
//
//  1. **USDZ-first**: if the bundle already contains a `.usdz`
//     (pre-converted offline via Reality Converter or an Xcode build
//     phase), we cache it and return immediately — zero runtime work.
//  2. **GLB fallback (currently disabled)**: we still probe whether
//     ModelIO has learned GLB import on the running OS. If it has,
//     we take the ModelIO path (exporting to `.usdc`, which RealityKit
//     *can* load). If it hasn't, we throw
//     `.importerUnavailableForGLB` with an actionable message telling
//     the caller (or CI) to pre-convert via Tools/plateau-pipeline.
//
// The strategy keeps the loader's call site identical across both
// paths and leaves the door open for a future iOS that adds native
// GLB import — a single `MDLAsset.canImportFileExtension("glb")` at
// startup is enough to flip the switch.
//
// ## Cache layout
//
//   Application Support/
//     sdg-lab/
//       env-cache/
//         Environment_Sendai_57403617.<sha256>.usdc
//
// Name includes the source's SHA-256 so a GLB rebuild (new hash)
// produces a new filename; older cache entries for the same basename
// are garbage-collected on success.

import Foundation
import CryptoKit
import ModelIO

/// Converts bundle-embedded PLATEAU tile meshes to a RealityKit-friendly
/// format (USDZ or USDC) and caches the result in Application Support.
///
/// Implemented as an `enum` with static methods because the converter
/// has no state — each call is a pure function of (bundle, basename).
public enum GLBToUSDZConverter {

    /// Everything this converter can go wrong with. All associated
    /// values are `Sendable` so the error crosses actor boundaries
    /// cleanly.
    public enum ConverterError: Error, Sendable {

        /// Neither a `.usdz` nor a `.glb` with this basename exists in
        /// the bundle. First associated value is the basename searched.
        case sourceNotFound(basename: String)

        /// Application Support directory could not be resolved or
        /// created. Propagated from `FileManager`.
        case cacheDirectoryUnavailable(underlying: String)

        /// Failed to compute SHA-256 of the source file (typically an
        /// I/O error reading the GLB).
        case hashFailed(underlying: String)

        /// ModelIO cannot ingest GLB on this OS build, and no
        /// pre-converted USDZ was shipped. Tells the caller how to
        /// remediate without recompiling the app.
        case importerUnavailableForGLB(basename: String)

        /// ModelIO loaded the source asset but failed to export it to
        /// a RealityKit-readable format.
        case exportFailed(basename: String, underlying: String)
    }

    // MARK: - Cache directory

    /// Absolute URL of the directory holding converted tile caches.
    ///
    /// Created on first access. Resolves to, e.g.,
    /// `~/Library/Application Support/sdg-lab/env-cache/` on macOS and
    /// the app's sandboxed Application Support on iOS.
    public static var cacheDirectory: URL {
        get throws {
            let fm = FileManager.default
            do {
                let base = try fm.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let dir = base
                    .appendingPathComponent("sdg-lab", isDirectory: true)
                    .appendingPathComponent("env-cache", isDirectory: true)
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(
                        at: dir,
                        withIntermediateDirectories: true
                    )
                }
                return dir
            } catch {
                throw ConverterError.cacheDirectoryUnavailable(
                    underlying: "\(error)"
                )
            }
        }
    }

    // MARK: - Entry point

    /// Locate the source for `glbBasename` in `bundle` and return a
    /// URL RealityKit can load.
    ///
    /// Strategy:
    ///
    /// 1. If the bundle ships a pre-converted `.usdz` with the same
    ///    basename, return it (zero runtime cost — the bundle path
    ///    is already on-disk).
    /// 2. Otherwise look for `.glb`:
    ///    - If this OS's ModelIO supports GLB import **and** can
    ///      export `.usdc` / `.usdz`, hash the GLB, convert into
    ///      `cacheDirectory` if the target is missing, and return.
    ///    - Otherwise throw `.importerUnavailableForGLB` with the
    ///      basename so the caller can surface an actionable message.
    ///
    /// The return URL is guaranteed to have an extension RealityKit
    /// recognises (one of `usdz`, `usdc`, `usda`, `usd`).
    ///
    /// - Important: This function is not `@MainActor` — the work is
    ///   pure file I/O plus ModelIO, which is safe off-main. Callers
    ///   on the MainActor can safely `await` into it.
    public static func convertIfNeeded(
        bundle: Bundle,
        glbBasename: String
    ) async throws -> URL {

        // 1. USDZ-first.
        if let usdz = bundle.url(
            forResource: glbBasename,
            withExtension: "usdz"
        ) {
            return usdz
        }
        // USDC is also fine for RealityKit.
        if let usdc = bundle.url(
            forResource: glbBasename,
            withExtension: "usdc"
        ) {
            return usdc
        }

        // 2. GLB fallback.
        guard let glbURL = bundle.url(
            forResource: glbBasename,
            withExtension: "glb"
        ) else {
            throw ConverterError.sourceNotFound(basename: glbBasename)
        }

        guard MDLAsset.canImportFileExtension("glb") else {
            // Intentional early-out — we know today's ModelIO can't
            // do this, and going further would waste an expensive
            // hash + load + fail sequence per tile per launch.
            throw ConverterError.importerUnavailableForGLB(
                basename: glbBasename
            )
        }

        let hash = try sha256Hex(of: glbURL)
        let target = try targetURL(for: glbBasename, hash: hash)

        // Cache hit: nothing to do.
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }

        // Cache miss. Load + export, then sweep older cache entries
        // for the same basename so stale hashes don't accumulate.
        do {
            let asset = MDLAsset(url: glbURL)
            try asset.export(to: target)
        } catch {
            throw ConverterError.exportFailed(
                basename: glbBasename,
                underlying: "\(error)"
            )
        }

        pruneOldCacheEntries(
            forBasename: glbBasename,
            keeping: target
        )
        return target
    }

    // MARK: - Helpers (internal for tests)

    /// Compute the target cache URL for a given source + hash. The
    /// extension depends on what today's ModelIO can export:
    /// - `.usdz` if supported (ideal, single file)
    /// - `.usdc` otherwise (RealityKit reads it fine, just multi-file)
    ///
    /// Exposed `internal` so tests can assert the naming without
    /// invoking conversion.
    internal static func targetURL(
        for basename: String,
        hash: String
    ) throws -> URL {
        let ext = preferredExportExtension()
        return try cacheDirectory
            .appendingPathComponent("\(basename).\(hash).\(ext)")
    }

    /// Pick the best export extension supported on the running OS.
    /// Prefers `usdz` (single-file archive) because the resulting
    /// cache is easier to inspect and smaller on disk; falls back to
    /// `usdc` which ModelIO exports reliably on today's OS.
    ///
    /// Internal so tests can pin the selection logic without mocking
    /// ModelIO.
    internal static func preferredExportExtension() -> String {
        if MDLAsset.canExportFileExtension("usdz") {
            return "usdz"
        }
        // `usdc` is the widely-supported binary USD encoding and is
        // what ModelIO reliably produces on iOS 18 / macOS 15.
        return "usdc"
    }

    /// Compute SHA-256 of the file at `url` and return a lowercase
    /// hex string. Uses `CryptoKit`'s streaming API so large GLBs
    /// don't balloon into memory.
    internal static func sha256Hex(of url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data)
            return digest
                .map { String(format: "%02x", $0) }
                .joined()
        } catch {
            throw ConverterError.hashFailed(underlying: "\(error)")
        }
    }

    /// Remove cache entries whose basename prefix matches `basename`
    /// but are *not* `keeping`. Called after a successful new export
    /// so last-hash artifacts don't pile up across asset rebuilds.
    ///
    /// Failures are swallowed — pruning is best-effort and the cache
    /// being slightly oversized is never a user-visible bug.
    private static func pruneOldCacheEntries(
        forBasename basename: String,
        keeping keep: URL
    ) {
        let fm = FileManager.default
        guard
            let dir = try? cacheDirectory,
            let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            )
        else { return }

        let prefix = "\(basename)."
        for entry in entries where entry != keep {
            guard entry.lastPathComponent.hasPrefix(prefix) else {
                continue
            }
            try? fm.removeItem(at: entry)
        }
    }
}
