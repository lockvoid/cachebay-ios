import Foundation
import CachebayGraphQL

public enum OperationKind: String, Hashable, Sendable {
    case query
    case mutation
    case subscription
    case fragment
}

public enum ConnectionMode: String, Hashable, Sendable {
    case infinite
    case page
}

/// One lowered field in a selection set.
///
/// Mirrors cachebay-web `PlanField` with Swift-idiomatic adjustments:
/// - `buildArgs` / `stringifyArgs` are `Sendable` closures.
/// - `selectionSet` is nil for leaf scalar fields; empty for missing children.
public struct PlanField: Hashable, Sendable {
    public let responseKey: String
    public let fieldName: String
    public let selectionSet: [PlanField]?
    public let selectionMap: [String: PlanField]?
    public let typeCondition: String?

    // Arguments
    public let expectedArgNames: [String]
    public let buildArgs: @Sendable (_ vars: [String: JSONValue]) -> [String: JSONValue]
    public let stringifyArgs: @Sendable (_ vars: [String: JSONValue]) -> String

    // Connection metadata (present when @connection directive exists)
    public let isConnection: Bool
    public let connectionKey: String?
    public let connectionFilters: [String]?
    public let connectionMode: ConnectionMode?
    public let pageArgs: [String]?

    /// Stable fingerprint for the subtree; used for plan.id and watcher dedup.
    public let selId: String

    public static func == (lhs: PlanField, rhs: PlanField) -> Bool {
        return lhs.selId == rhs.selId
            && lhs.responseKey == rhs.responseKey
            && lhs.fieldName == rhs.fieldName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(selId)
    }
}

public struct VarMask: Hashable, Sendable {
    public let strict: [String]
    public let canonical: [String]
}

public struct CachePlan: Hashable, Sendable {
    public let operation: OperationKind
    public let rootTypename: String
    public let root: [PlanField]
    public let rootSelectionMap: [String: PlanField]

    /// Network-safe query string (with `__typename` added, `@connection` stripped).
    public let networkQuery: String

    /// Stable numeric ID derived from the root fingerprint (FNV-1a32).
    public let id: UInt32

    public let varMask: VarMask

    /// Windows args are pagination args (first/last/after/before) recorded
    /// while lowering each connection field.
    public let windowArgs: Set<String>

    /// Stable selection fingerprint for debugging / traceability.
    public let selectionFingerprint: String

    public static func == (lhs: CachePlan, rhs: CachePlan) -> Bool {
        return lhs.id == rhs.id
            && lhs.operation == rhs.operation
            && lhs.rootTypename == rhs.rootTypename
            && lhs.varMask == rhs.varMask
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(operation)
    }

    // MARK: - Helpers

    public func makeVarsKey(canonical: Bool, variables: [String: JSONValue]) -> String {
        let mask = canonical ? varMask.canonical : varMask.strict
        if mask.isEmpty { return "{}" }
        let sorted = mask.sorted()
        var parts: [String] = []
        for k in sorted {
            if let v = variables[k] {
                parts.append(encodeJSONString(k) + ":" + stableStringify(v))
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    public func makeSignature(canonical: Bool, variables: [String: JSONValue]) -> String {
        let mode = canonical ? "canonical" : "strict"
        return "\(id)|\(mode)|\(makeVarsKey(canonical: canonical, variables: variables))"
    }

    /// Build a coarse dependency set for this query at these variables
    /// (used for watcher pre-registration). Connection fields contribute both
    /// the canonical and strict keys.
    public func getDependencies(canonical: Bool, variables: [String: JSONValue]) -> Set<CacheKey> {
        var deps: Set<CacheKey> = []
        collectDeps(fields: root, parentTypename: rootTypename, canonical: canonical, variables: variables, into: &deps)
        return deps
    }

    private func collectDeps(fields: [PlanField], parentTypename: String, canonical: Bool, variables: [String: JSONValue], into deps: inout Set<CacheKey>) {
        for field in fields {
            let parentId = parentTypename == rootTypename ? CachebayConstants.rootID : parentTypename
            if field.isConnection {
                let key = canonical
                    ? Keys.buildConnectionCanonicalKey(field: field, parentId: parentId, variables: variables)
                    : Keys.buildConnectionKey(field: field, parentId: parentId, variables: variables)
                deps.insert(key)
            } else if !field.expectedArgNames.isEmpty {
                deps.insert(Keys.buildFieldKey(field: field, variables: variables))
            }
            if let children = field.selectionSet {
                let nextParent = field.typeCondition ?? parentTypename
                collectDeps(fields: children, parentTypename: nextParent, canonical: canonical, variables: variables, into: &deps)
            }
        }
    }
}
