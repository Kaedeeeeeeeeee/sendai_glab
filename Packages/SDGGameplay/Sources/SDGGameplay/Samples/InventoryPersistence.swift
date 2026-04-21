// InventoryPersistence.swift
// SDGGameplay
//
// Storage backend for `InventoryStore`. Pure data-in / data-out; no
// knowledge of the store or the event bus. The default backend uses
// `UserDefaults` (Apple documents it as thread-safe and `Sendable`);
// an `.inMemory` backend is provided for tests so they never pollute
// the real defaults database.

import Foundation

/// A small pluggable persistence façade for the sample inventory.
///
/// The type is modeled as a `struct` of two `@Sendable` closures instead
/// of a protocol so that:
/// - Call sites stay value-typed and trivially `Sendable` (strict
///   concurrency under Swift 6 flags this for protocol existentials
///   otherwise).
/// - Tests can build a bespoke instance inline without defining a mock
///   class just to conform to a protocol.
///
/// ### Backends
/// - ``standard``: `UserDefaults.standard` under the key
///   `"sdg.inventory.v1"`. Versioning the key protects against future
///   schema changes — bump to `v2` and the old blob is simply ignored.
/// - ``userDefaults(_:)``: same as `.standard` but with a caller-supplied
///   `UserDefaults` instance (tests use `UserDefaults(suiteName:)` to get
///   an isolated store they can tear down).
/// - ``inMemory``: pure RAM, per-instance — for unit tests that assert
///   save/load round-trips without touching the defaults database.
///
/// ### Concurrency
/// The struct itself is `Sendable`. The two closures may be invoked from
/// any isolation domain. `UserDefaults` is documented as thread-safe;
/// `JSONEncoder` / `JSONDecoder` are created fresh inside each closure
/// invocation (they are *not* `Sendable`), which is cheap and side-steps
/// sharing.
///
/// ### Error model
/// - `save` throws if encoding fails or the backing store rejects the
///   write (in practice: `.inMemory` never throws; UserDefaults never
///   throws either, since its API is non-throwing, but a bad encoder
///   configuration would).
/// - `load` throws on malformed JSON. A *missing* entry is **not** an
///   error and returns `[]` — empty-inventory is the legitimate initial
///   state on first launch.
public struct InventoryPersistence: Sendable {

    /// Persisted schema version. Bump when the on-disk shape of
    /// `[SampleItem]` changes incompatibly.
    public static let schemaKey = "sdg.inventory.v1"

    /// Save `samples` to the backing store, replacing any prior payload.
    private let saveImpl: @Sendable ([SampleItem]) throws -> Void

    /// Load samples. Returns `[]` when the backing store holds nothing
    /// yet; throws when the backing store holds malformed data.
    private let loadImpl: @Sendable () throws -> [SampleItem]

    /// Non-public init: callers get an instance via one of the factory
    /// statics below so the backend choice is explicit at the call site.
    private init(
        save: @escaping @Sendable ([SampleItem]) throws -> Void,
        load: @escaping @Sendable () throws -> [SampleItem]
    ) {
        self.saveImpl = save
        self.loadImpl = load
    }

    /// Default backend: `UserDefaults.standard` at key
    /// `"sdg.inventory.v1"`. Suitable for production.
    public static let standard: InventoryPersistence = .userDefaults(.standard)

    /// UserDefaults-backed persistence with a caller-supplied defaults
    /// instance. Use in tests with `UserDefaults(suiteName:)` to get an
    /// isolated store you can purge at teardown.
    ///
    /// ### Sendable workaround
    /// `UserDefaults` is documented thread-safe by Apple, but the
    /// Foundation overlay has not yet annotated it as `Sendable`. We
    /// capture the reference through an `@unchecked Sendable` box so the
    /// closures the struct stores can themselves be `@Sendable` without
    /// producing strict-concurrency warnings. The box is sound because
    /// every read/write on the enclosed `UserDefaults` goes through
    /// Foundation's own internal locking.
    public static func userDefaults(_ defaults: UserDefaults) -> InventoryPersistence {
        let key = Self.schemaKey
        let box = UserDefaultsBox(defaults: defaults)
        return InventoryPersistence(
            save: { samples in
                // JSONEncoder is not Sendable; build one per-call. Cost
                // is negligible vs. the UserDefaults write itself.
                let data = try JSONEncoder().encode(samples)
                box.defaults.set(data, forKey: key)
            },
            load: {
                guard let data = box.defaults.data(forKey: key) else {
                    // Missing entry = first launch; not an error.
                    return []
                }
                return try JSONDecoder().decode([SampleItem].self, from: data)
            }
        )
    }

    /// Private wrapper that lets us pass a `UserDefaults` through a
    /// `@Sendable` closure. See `userDefaults(_:)` for the rationale.
    private final class UserDefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults
        init(defaults: UserDefaults) { self.defaults = defaults }
    }

    /// In-memory backend for tests. Each call to `.inMemory` returns a
    /// fresh, independent instance — state does not leak across tests.
    ///
    /// Implemented via `NSLock` rather than an `actor` so the struct's
    /// two closures can remain synchronous (`throws` but not `async`),
    /// matching the UserDefaults variant's signature.
    public static var inMemory: InventoryPersistence {
        // Reference box holding the ephemeral data + lock. Captured by
        // the two closures so they share state.
        //
        // `@unchecked Sendable` is sound here: every read/write is
        // guarded by the `NSLock`.
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var samples: [SampleItem] = []
        }
        let box = Box()
        return InventoryPersistence(
            save: { samples in
                box.lock.lock()
                defer { box.lock.unlock() }
                box.samples = samples
            },
            load: {
                box.lock.lock()
                defer { box.lock.unlock() }
                return box.samples
            }
        )
    }

    /// Persist the given samples. See the struct doc for the error model.
    public func save(_ samples: [SampleItem]) throws {
        try saveImpl(samples)
    }

    /// Load previously-persisted samples, or `[]` if none were saved.
    public func load() throws -> [SampleItem] {
        try loadImpl()
    }
}
