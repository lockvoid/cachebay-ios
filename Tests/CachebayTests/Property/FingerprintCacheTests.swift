import XCTest
@testable import Cachebay

/// Property tests for the §5.1 invariant: the materialise fingerprint
/// cache must produce the same observable result as a from-scratch
/// re-materialisation. A bug here is silent — a watcher reads a record
/// that didn't register as a dep, the record changes, the fingerprint
/// short-circuits the re-walk, and the watcher's last emission is now
/// stale forever.
///
/// Strategy: pick a fixed query plan, randomly mutate the underlying
/// graph state, and after every mutation assert that the watcher's
/// cached `onData` payload equals a fresh `materialize(preferCache:
/// false)` against the same vars. Anything that diverges is the bug
/// the architecture doc flags.
final class FingerprintCacheTests: XCTestCase {

    // Bumping this flushes more state per run; CI wants fast, dev wants
    // thorough. Tune via env if we ever need to reproduce a flake.
    private let opsPerRun = 50
    private let runs = 3

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    /// Deterministic-ish RNG seeded per run so a failure is reproducible
    /// from the printed seed. Conforms to `RandomNumberGenerator` so
    /// Swift's `Array.randomElement(using:)` works out of the box.
    /// `SystemRandomNumberGenerator` isn't seedable.
    fileprivate struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            // splitmix64 — fine for tests, not for crypto.
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
        mutating func bool() -> Bool { next() % 2 == 0 }
    }

    // MARK: - Single-record fuzz

    /// Watch one entity. Randomly mutate its scalar fields. After every
    /// mutation, compare the watcher's last emission to a from-scratch
    /// materialisation. If they diverge, the fingerprint cache is wrong
    /// for some field — and the watcher would silently show stale data
    /// in production.
    func test_property_singleEntity_cachedEqualsFresh() throws {
        for run in 0..<runs {
            let seed = UInt64(run + 1) &* 0xDEADBEEF
            try runSingleEntityProperty(seed: seed)
        }
    }

    private func runSingleEntityProperty(seed: UInt64) throws {
        let client = makeClient()
        var rng = Rng(state: seed)

        let querySource = "query User($id: ID!) { user(id: $id) { id name email age active } }"
        let plan = try client.planner.getPlan(.source(querySource))
        let vars: [String: JSONValue] = ["id": .string("u1")]

        // Initial state.
        try client.writeQuery(query: querySource, variables: vars, data: .object([
            "user": .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "name": .string("Alice"),
                "email": .string("alice@example.com"),
                "age": .int(30),
                "active": .bool(true),
            ])
        ]))

        let lastEmission = CaptureBox<JSONValue>(value: .undefined)
        let handle = try client.watchQuery(
            query: querySource,
            options: WatchQueryOptions(
                variables: vars,
                immediate: true,
                onData: { lastEmission.value = $0 }
            )
        )
        defer { handle.unsubscribe() }

        // Initial sanity — cached watcher emission must match fresh
        // materialise right out of the gate.
        try assertCachedEqualsFresh(client: client, plan: plan, variables: vars, cached: lastEmission.value, seed: seed, opIndex: -1)

        for op in 0..<opsPerRun {
            // Pick a random field to mutate. Build the user dict
            // mutably to avoid Swift's dictionary-literal duplicate-key
            // trap when `field` matches one of the placeholder keys.
            let field = ["name", "email", "age", "active"].randomElement(using: &rng)!
            var user: [String: JSONValue] = [
                "__typename": .string("User"),
                "id": .string("u1"),
                "name": .string("placeholder"),
                "email": .string("placeholder@example.com"),
                "age": .int(0),
                "active": .bool(false),
            ]
            switch field {
            case "name": user["name"] = .string("name-\(rng.next())")
            case "email": user["email"] = .string("e\(rng.next())@example.com")
            case "age": user["age"] = .int(Int64(rng.int(100)))
            case "active": user["active"] = .bool(rng.bool())
            default: continue
            }

            try client.writeQuery(query: querySource, variables: vars, data: .object([
                "user": .object(user),
            ]))

            try assertCachedEqualsFresh(client: client, plan: plan, variables: vars, cached: lastEmission.value, seed: seed, opIndex: op)
        }
    }

    // MARK: - Nested-object property

    /// The most realistic stale-data shape: a watcher reads `user.profile.bio`
    /// where `Profile` is a separate normalised entity. If the dep on
    /// `Profile:p1` isn't registered when the watcher walks through
    /// `user.profile`, mutating Profile silently goes unnoticed.
    func test_property_nestedEntity_profileChangesPropagate() throws {
        for run in 0..<runs {
            let seed = UInt64(run + 1) &* 0xCAFEBABE
            try runNestedEntityProperty(seed: seed)
        }
    }

    private func runNestedEntityProperty(seed: UInt64) throws {
        let client = makeClient()
        var rng = Rng(state: seed)

        let querySource = """
        query User($id: ID!) {
          user(id: $id) {
            id
            name
            profile { id bio avatar }
          }
        }
        """
        let plan = try client.planner.getPlan(.source(querySource))
        let vars: [String: JSONValue] = ["id": .string("u1")]

        try client.writeQuery(query: querySource, variables: vars, data: .object([
            "user": .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "name": .string("Alice"),
                "profile": .object([
                    "__typename": .string("Profile"),
                    "id": .string("p1"),
                    "bio": .string("hi"),
                    "avatar": .string("a.png"),
                ]),
            ])
        ]))

        let lastEmission = CaptureBox<JSONValue>(value: .undefined)
        let handle = try client.watchQuery(
            query: querySource,
            options: WatchQueryOptions(
                variables: vars,
                immediate: true,
                onData: { lastEmission.value = $0 }
            )
        )
        defer { handle.unsubscribe() }

        try assertCachedEqualsFresh(client: client, plan: plan, variables: vars, cached: lastEmission.value, seed: seed, opIndex: -1)

        for op in 0..<opsPerRun {
            // Mix mutations on the User and on the Profile entity. A bug
            // in dep tracking would manifest as: mutate Profile, watcher
            // never refires, lastEmission stays stale.
            let target = rng.bool() ? "user" : "profile"

            if target == "user" {
                // Only `name` is patchable on the user via this path —
                // mutate it freshly each time. Build the dict mutably
                // to keep the field-substitution shape symmetric with
                // the single-entity test.
                var user: [String: JSONValue] = [
                    "__typename": .string("User"),
                    "id": .string("u1"),
                    "name": .string("placeholder"),
                    "profile": .object([
                        "__typename": .string("Profile"),
                        "id": .string("p1"),
                        "bio": .string("placeholder"),
                        "avatar": .string("placeholder"),
                    ]),
                ]
                user["name"] = .string("name-\(rng.next())")
                try client.writeQuery(query: querySource, variables: vars, data: .object([
                    "user": .object(user),
                ]))
            } else {
                // Mutate Profile via writeFragment — bypasses the user
                // query's normalisation but writes to the same canonical
                // Profile:p1 record. If the watcher's dep set didn't
                // register Profile:p1, this goes undetected.
                try client.writeFragment(
                    id: "Profile:p1",
                    fragment: "fragment P on Profile { id bio avatar }",
                    data: .object([
                        "__typename": .string("Profile"),
                        "id": .string("p1"),
                        "bio": .string("bio-\(rng.next())"),
                        "avatar": .string("avatar-\(rng.next()).png"),
                    ])
                )
            }

            try assertCachedEqualsFresh(client: client, plan: plan, variables: vars, cached: lastEmission.value, seed: seed, opIndex: op)
        }
    }

    // MARK: - assertion helper

    /// Materialise from scratch (cache disabled) and compare to whatever
    /// the watcher's `onData` last received. Print the seed + op index
    /// on divergence so a CI flake reproduces deterministically.
    private func assertCachedEqualsFresh(
        client: CachebayClient,
        plan: CachePlan,
        variables: [String: JSONValue],
        cached: JSONValue,
        seed: UInt64,
        opIndex: Int
    ) throws {
        let fresh = client.documents.materialize(
            plan: plan,
            variables: variables,
            options: .init(canonical: true, fingerprint: false, preferCache: false, updateCache: false)
        )
        guard fresh.source != .none else {
            XCTFail("fresh materialise returned no data — seed=\(seed) op=\(opIndex)")
            return
        }
        XCTAssertEqual(
            cached, fresh.data,
            "watcher cached emission diverged from fresh materialise — seed=\(seed) op=\(opIndex). Cached=\(cached) Fresh=\(fresh.data)"
        )
    }
}

