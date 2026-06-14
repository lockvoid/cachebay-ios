//  GraphQLNullable.swift
//
//  Tri-state wrapper for **nullable input** positions (input-object fields and
//  operation variables). GraphQL distinguishes three states for a nullable
//  input, and the difference is observable to resolvers — the spec (§Input
//  Coercion) is explicit: *"there is a semantic difference between the
//  explicitly provided value null versus having not provided a value."*
//
//      • OMIT   — field absent from the wire → resolver kwarg not present
//                 → "leave untouched"                       → `.none` / `nil`
//      • NULL   — field present as JSON `null`              → "clear / set null"
//                 → resolver kwarg present and nil          → `.null`
//      • VALUE  — field present with a value                → `.some(x)`
//
//  A plain Swift `Optional` collapses OMIT and NULL into a single `nil`, so a
//  generated serializer built on it can only ever emit explicit-null — it can
//  never OMIT a field. That silently turns every "patch one field" mutation
//  into "overwrite every other field with null." This type restores the
//  distinction; it mirrors Apollo's `GraphQLNullable` so the idiom is familiar.
//
//  Ergonomics: `nil` (and the generated `= nil` default) means OMIT, so the
//  common "I didn't set this" case stays clean. Literals wrap into `.some`
//  (`name: "x"`, `count: 3`, `tags: ["a"]`). A non-literal value is `.some(x)`;
//  an explicit clear is `.null`.

/// A nullable GraphQL input value: omitted (`.none`), explicit null (`.null`),
/// or a value (`.some`). See file header for the semantics.
public enum GraphQLNullable<Wrapped: Sendable>: Sendable {
    /// Omit the field entirely from the serialized input ("leave untouched").
    case none
    /// Send an explicit JSON `null` ("clear / set to null").
    case null
    /// Send a value.
    case some(Wrapped)

    /// The wrapped value if this is `.some`, else `nil`. (`.null` unwraps to
    /// `nil` — it carries no value.)
    @inlinable public var unwrapped: Wrapped? {
        guard case let .some(w) = self else { return nil }
        return w
    }

    /// Bridge a plain `Optional` into the tri-state: `nil` → OMIT (`.none`), a
    /// value → `.some`. An `Optional` cannot express explicit-null, so this
    /// never yields `.null` — pass `.null` directly to send one. Handy for
    /// forwarding an existing `T?` (a pagination cursor, a search string) to a
    /// tri-state input without spelling out the `.some`/`.none` mapping.
    @inlinable public init(_ optional: Wrapped?) {
        self = optional.map(GraphQLNullable.some) ?? .none
    }
}

// MARK: - Wire encoding

extension GraphQLNullable {
    /// Encode this input value for the wire. Returns:
    ///   • `nil`   when the field must be **omitted** (`.none`) — the caller
    ///     skips the key, so it never appears in the payload.
    ///   • `.null` for an explicit null (`.null`).
    ///   • `transform(value)` for `.some(value)`.
    ///
    /// The generated `__cachebay` serializers call this and only assign the key
    /// when the result is non-nil (`if let v = field.__cachebayEncode(...) { … }`),
    /// which is what makes OMIT distinct from NULL on the wire.
    @inlinable
    public func __cachebayEncode(_ transform: (Wrapped) -> JSONValue) -> JSONValue? {
        switch self {
        case .none: return nil
        case .null: return JSONValue.null
        case .some(let w): return transform(w)
        }
    }
}

// MARK: - ExpressibleByNilLiteral  (nil → OMIT)

extension GraphQLNullable: ExpressibleByNilLiteral {
    /// `nil` means "I didn't provide this" → OMIT (`.none`). An explicit null is
    /// the distinct `.null` case — never reachable via `nil`.
    @inlinable public init(nilLiteral: ()) { self = .none }
}

// MARK: - Literal conformances  (literal → .some(value))

extension GraphQLNullable: ExpressibleByUnicodeScalarLiteral
where Wrapped: ExpressibleByUnicodeScalarLiteral {
    @inlinable public init(unicodeScalarLiteral value: Wrapped.UnicodeScalarLiteralType) {
        self = .some(Wrapped(unicodeScalarLiteral: value))
    }
}

extension GraphQLNullable: ExpressibleByExtendedGraphemeClusterLiteral
where Wrapped: ExpressibleByExtendedGraphemeClusterLiteral {
    @inlinable public init(extendedGraphemeClusterLiteral value: Wrapped.ExtendedGraphemeClusterLiteralType) {
        self = .some(Wrapped(extendedGraphemeClusterLiteral: value))
    }
}

extension GraphQLNullable: ExpressibleByStringLiteral
where Wrapped: ExpressibleByStringLiteral {
    @inlinable public init(stringLiteral value: Wrapped.StringLiteralType) {
        self = .some(Wrapped(stringLiteral: value))
    }
}

extension GraphQLNullable: ExpressibleByIntegerLiteral
where Wrapped: ExpressibleByIntegerLiteral {
    @inlinable public init(integerLiteral value: Wrapped.IntegerLiteralType) {
        self = .some(Wrapped(integerLiteral: value))
    }
}

extension GraphQLNullable: ExpressibleByFloatLiteral
where Wrapped: ExpressibleByFloatLiteral {
    @inlinable public init(floatLiteral value: Wrapped.FloatLiteralType) {
        self = .some(Wrapped(floatLiteral: value))
    }
}

extension GraphQLNullable: ExpressibleByBooleanLiteral
where Wrapped: ExpressibleByBooleanLiteral {
    @inlinable public init(booleanLiteral value: Wrapped.BooleanLiteralType) {
        self = .some(Wrapped(booleanLiteral: value))
    }
}

/// Bridges an array literal into an arbitrary `Wrapped` collection (almost
/// always `Array`) for `ExpressibleByArrayLiteral`. Uniquely named to avoid
/// colliding with `Array`'s own `init(_:)`.
public protocol _InitializableByArrayLiteralElements {
    associatedtype ArrayLiteralElement
    init(_graphQLNullableArrayLiteral elements: [ArrayLiteralElement])
}

extension Array: _InitializableByArrayLiteralElements {
    @inlinable public init(_graphQLNullableArrayLiteral elements: [Element]) { self = elements }
}

extension GraphQLNullable: ExpressibleByArrayLiteral
where Wrapped: _InitializableByArrayLiteralElements {
    @inlinable public init(arrayLiteral elements: Wrapped.ArrayLiteralElement...) {
        self = .some(Wrapped(_graphQLNullableArrayLiteral: elements))
    }
}

// MARK: - Equatable / Hashable

extension GraphQLNullable: Equatable where Wrapped: Equatable {}
extension GraphQLNullable: Hashable where Wrapped: Hashable {}
