// AudioService.swift
// SDGPlatform · Audio
//
// An `AVAudioPlayer` pool that plays short SFX cues (`AudioEffect`).
//
// ## Why AVAudioPlayer rather than AVAudioEngine / PHASE?
//
// Phase 2 Alpha ships fire-and-forget 2-D SFX with no spatialisation,
// no ducking, no DSP. `AVAudioPlayer` handles that surface with a
// tiny API and no graph setup. When spatial / HRTF needs appear
// (Phase 3 per GDD §2.1), the façade (`play(_:volume:)`) can be
// re-implemented on top of `AVAudioEngine` without churning callers.
//
// ## Why @MainActor?
//
// `AVAudioPlayer` is *not* `Sendable`. iOS 18's Swift 6 concurrency
// flags every non-`@MainActor` hold of an `AVAudioPlayer` reference
// as unsafe if it crosses a suspension point. Binding the whole
// service to `@MainActor` gives us one consistent isolation and
// matches the call sites: both SwiftUI handlers and RealityKit
// `SceneUpdateContext` run on `MainActor` anyway.
//
// ## Why no singleton?
//
// AGENTS.md Rule 2. The app entry point constructs one `AudioService`
// and injects it via `AppEnvironment`. Tests construct fresh ones.
//
// ## Pool strategy
//
// One cached `AVAudioPlayer` per candidate URL. First `play(effect:)`
// lazily loads the player(s); subsequent calls reuse them. If the
// cached player is still playing when another request arrives, we
// fork a temporary player (single-use) rather than cut the first one
// short — that matches the way fighting-game SFX overlap. Temporary
// players are released once they finish via the delegate callback.

import AVFoundation
import Foundation
import SDGCore

/// Platform-side sound-effect player. Plays short `.ogg` cues
/// registered in `AudioEffect` from the app bundle (or an injected
/// test bundle).
///
/// The service is `@MainActor`-isolated because `AVAudioPlayer` is not
/// `Sendable`; see the file header for the rationale.
///
/// The class is `open` (not `final`) so cross-module test fixtures
/// can subclass it and override `play(_:volume:)` to record
/// invocations without touching audio hardware. Production callers
/// should treat it as final; subclassing is reserved for tests.
@MainActor
open class AudioService {

    // MARK: - Types

    /// Error surfaces produced by the service. Currently used only for
    /// diagnostic logging — `play(_:volume:)` does not throw; it
    /// silently no-ops and returns `nil` on lookup failure so a missing
    /// asset never crashes the game in production.
    public enum AudioError: Error, Sendable {
        /// The requested effect resolved to a resource name, but the
        /// bundle didn't contain a file with that name + `.ogg`.
        case resourceNotFound(basename: String, category: String)
        /// `AVAudioPlayer(contentsOf:)` threw. Wrapped for logging.
        case playerInitFailed(String)
    }

    // MARK: - Configuration

    /// Bundle the service queries for audio resources. Production code
    /// passes `.main`; tests inject `Bundle.module` (or a stub) so the
    /// suite doesn't rely on the host app having the SFX stapled in.
    private let bundle: Bundle

    /// Sub-directory inside the bundle where `<category>/<basename>.ogg`
    /// files live. Production ships the tree at
    /// `Resources/Audio/SFX/`, so this default matches.
    private let subdirectory: String

    // MARK: - State

    /// Global gain applied on top of each `play(_:volume:)` call's
    /// local `volume`. `0.0` mutes all SFX; `1.0` passes through. The
    /// settings UI (Phase 3) exposes this via a slider.
    public var masterVolume: Float {
        didSet {
            // Clamp defensively so odd UI states can't blow up the mix.
            masterVolume = max(0.0, min(1.0, masterVolume))
        }
    }

    /// Cached players keyed first by cue (`AudioEffect`) and then by
    /// concrete file `URL`. One `URL` → one cached `AVAudioPlayer`.
    /// When a cached player is still mid-playback a new request forks
    /// an ephemeral player rather than blocking or truncating the
    /// first sound — see `play(_:volume:)` for that branch.
    private var cache: [AudioEffect: [URL: AVAudioPlayer]] = [:]

    /// Strong references to ephemeral one-shot players that were
    /// forked because the cached player for the same URL was still
    /// playing. We retain them here so ARC doesn't release the player
    /// mid-sample; the delegate callback removes them when playback
    /// ends. Keyed by `UUID` so individual one-shots can be cancelled
    /// if `stopAll()` is invoked.
    private var transientPlayers: [UUID: AVAudioPlayer] = [:]

    /// Delegate that ushers `transientPlayers` entries out of the
    /// dictionary once their sample finishes. A single shared delegate
    /// keeps the class allocation cost at one regardless of how many
    /// sounds are in flight.
    private let releaseDelegate: TransientPlayerReleaseDelegate

    // MARK: - Init

    /// Create an audio service. The initialiser *does not* touch
    /// `AVAudioSession` or load any files — audio activation happens
    /// lazily on the first successful `play(_:volume:)` so unit tests
    /// that never play can construct the service without side effects.
    ///
    /// - Parameters:
    ///   - bundle: Resource bundle to search. Default: `.main`.
    ///   - subdirectory: Path relative to the bundle root. Default
    ///     matches the on-disk layout defined in `Resources/Audio/README.md`.
    ///   - masterVolume: Initial master-volume multiplier (0…1).
    public init(
        bundle: Bundle = .main,
        subdirectory: String = "Audio/SFX",
        masterVolume: Float = 1.0
    ) {
        self.bundle = bundle
        self.subdirectory = subdirectory
        self.masterVolume = max(0.0, min(1.0, masterVolume))
        self.releaseDelegate = TransientPlayerReleaseDelegate()
        // The delegate needs a way to nudge us when a one-shot ends.
        // We can't pass `self` in via the initialiser because `self`
        // isn't fully constructed; assign afterwards.
        self.releaseDelegate.owner = self
    }

    // MARK: - Public API

    /// Play an effect cue once.
    ///
    /// - Parameters:
    ///   - effect: Cue identifier.
    ///   - volume: Per-call gain multiplier (0…1). Final volume =
    ///     `volume * masterVolume`.
    /// - Returns: A handle for the playback, or `nil` if the resource
    ///   could not be resolved or the player failed to initialise.
    ///   Callers typically ignore the handle (fire-and-forget).
    ///
    /// Never throws: SFX are best-effort UX candy; a missing asset or
    /// corrupt file should not abort gameplay. Failures are logged via
    /// the returned `nil` and the (future) `os.log` channel.
    @discardableResult
    open func play(_ effect: AudioEffect, volume: Float = 1.0) -> UUID? {
        // Pick a URL. Variant cues sample uniformly; single-file cues
        // return the lone URL. A nil here means "no candidate bundle
        // resource at all" — bail out silently.
        guard let url = pickURL(for: effect) else {
            return nil
        }

        // Compute effective gain once so both the cached-player and
        // transient-player branches apply the same math.
        let effectiveVolume = max(0.0, min(1.0, volume)) * masterVolume

        // Cached branch: if the URL's player exists and is idle, rewind
        // and play. If it's busy, fall through to the transient branch
        // so overlapping plays don't truncate each other.
        if let cached = cache[effect]?[url] {
            if !cached.isPlaying {
                cached.currentTime = 0
                cached.volume = effectiveVolume
                return cached.play() ? UUID() : nil
            }
            // Busy: fall through to make a fresh one-shot instance.
        } else {
            // First play of this URL in this session — create, cache,
            // play once. Keeps the hot path at one allocation per cue.
            if let player = makePlayer(url: url, volume: effectiveVolume) {
                cache[effect, default: [:]][url] = player
                return player.play() ? UUID() : nil
            }
            return nil
        }

        // Transient branch: cached player is mid-sample. Spin up a
        // one-shot, retain until it finishes, then drop it.
        guard let oneShot = makePlayer(url: url, volume: effectiveVolume) else {
            return nil
        }
        let handle = UUID()
        oneShot.delegate = releaseDelegate
        transientPlayers[handle] = oneShot
        return oneShot.play() ? handle : nil
    }

    /// Stop every sound the service currently knows about. Cached
    /// players are stopped in place (they're reusable), transient
    /// one-shots are dropped.
    public func stopAll() {
        for urls in cache.values {
            for player in urls.values where player.isPlaying {
                player.stop()
                player.currentTime = 0
            }
        }
        for player in transientPlayers.values where player.isPlaying {
            player.stop()
        }
        transientPlayers.removeAll(keepingCapacity: false)
    }

    // MARK: - Internals

    /// Resolve a cue to a concrete bundle URL, sampling variants as
    /// needed. `nil` if none of the candidates exist in the bundle.
    private func pickURL(for effect: AudioEffect) -> URL? {
        let candidates = effect.resolveResourceNames()
        // Filter to only those present in the bundle — tests and
        // partially-populated bundles otherwise yield random misses.
        let resolved: [URL] = candidates.compactMap { basename in
            bundle.url(
                forResource: basename,
                withExtension: "ogg",
                subdirectory: "\(subdirectory)/\(effect.category)"
            )
        }
        return resolved.randomElement()
    }

    /// Create and prepare an `AVAudioPlayer` for a URL, applying
    /// `volume`. Returns `nil` (rather than throwing) so callers can
    /// stay fire-and-forget. The AVFoundation error description is
    /// carried in the caught log line for post-hoc diagnosis.
    private func makePlayer(url: URL, volume: Float) -> AVAudioPlayer? {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.prepareToPlay()
            return player
        } catch {
            // Deliberately swallow: SFX failures should not interrupt
            // the player. Production will attach os.log; tests simply
            // observe the `nil` return.
            return nil
        }
    }

    /// Called by `TransientPlayerReleaseDelegate` after any one-shot
    /// finishes. Removes every transient player that is no longer
    /// playing — we sweep rather than target a specific instance
    /// because `AVAudioPlayer` is not `Sendable` and forwarding the
    /// finished instance across the delegate's queue boundary would
    /// require unsafe transfer. Sweeping is O(n) where n is the
    /// (small) count of overlapping one-shots.
    fileprivate func sweepFinishedTransients() {
        transientPlayers = transientPlayers.filter { $0.value.isPlaying }
    }

    // MARK: - Test-only introspection

    /// Number of cached `AVAudioPlayer`s held for a given cue.
    /// Exposed so tests can assert that lazy init and URL caching
    /// behave as specified without needing to observe side effects.
    public func cachedPlayerCount(for effect: AudioEffect) -> Int {
        cache[effect]?.count ?? 0
    }

    /// Number of transient one-shot players currently retained.
    public var transientPlayerCount: Int {
        transientPlayers.count
    }
}

// MARK: - Delegate

/// Object-type delegate hook so ephemeral `AVAudioPlayer`s can phone
/// home when they finish. `NSObject` subclass because
/// `AVAudioPlayerDelegate` is `@objc`.
///
/// The delegate is *not* `@MainActor`: `AVAudioPlayerDelegate`
/// methods are invoked on AVFoundation's private queue, so the
/// callback must be nonisolated. We hop back to `MainActor` inside
/// the callback body to mutate the owner's dictionaries.
///
/// `owner` is a `Mutex`-free single-writer reference: it is set once
/// at initialiser time (before the delegate is ever used) and never
/// mutated afterwards. We therefore mark it `nonisolated(unsafe)` —
/// "unsafe" in the Swift-6 sense only; the usage pattern is
/// single-threaded by construction.
private final class TransientPlayerReleaseDelegate: NSObject, AVAudioPlayerDelegate {

    /// Weak back-pointer to the owning service. `weak` prevents a
    /// retain cycle between service → delegate → service.
    ///
    /// See the class-level comment for why `nonisolated(unsafe)` is
    /// acceptable here.
    nonisolated(unsafe) weak var owner: AudioService?

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        // AVFoundation calls this on its own queue. We hop to the
        // main queue and ask the owner to sweep any transient
        // players that are no longer playing. We deliberately do
        // *not* forward `player` across the queue boundary —
        // `AVAudioPlayer` is not `Sendable` and Swift 6 flags any
        // capture into an isolated closure. A sweep is O(n) where
        // n = currently-overlapping one-shots, which is 1–3 in
        // practice (fighting-game SFX overlap rate).
        let capturedOwner = owner
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                capturedOwner?.sweepFinishedTransients()
            }
        }
    }
}
