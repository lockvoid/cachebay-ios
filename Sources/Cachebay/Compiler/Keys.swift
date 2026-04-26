import Foundation

/// Cache-key builders shared by compiler (fingerprinting) and runtime
/// (normalize / materialize / canonical). Pure functions over `PlanField`
/// plus runtime variables — no state.
public enum Keys {
    /// Build a field storage key used on a record snapshot.
    /// `user({"id":"u1"})` for argumented fields; plain field name otherwise.
    public static func buildFieldKey(field: PlanField, variables: [String: JSONValue]) -> String {
        let args = field.stringifyArgs(variables)
        if args.isEmpty || args == "{}" { return field.fieldName }
        return field.fieldName + "(" + args + ")"
    }

    /// Build the per-page connection key, e.g. `@.posts({"first":10,"after":"c2"})`.
    public static func buildConnectionKey(field: PlanField, parentId: String, variables: [String: JSONValue]) -> String {
        let base: String
        if parentId.hasPrefix(CachebayConstants.rootID) {
            base = parentId
        } else {
            base = "\(CachebayConstants.rootID).\(parentId)"
        }
        return "\(base).\(field.fieldName)(\(field.stringifyArgs(variables)))"
    }

    /// Build the canonical (filters-only) connection key under `@connection.`, e.g.
    /// `@connection.posts({"category":"tech"})` or `@connection.User:u1.posts({})`.
    public static func buildConnectionCanonicalKey(field: PlanField, parentId: String, variables: [String: JSONValue]) -> String {
        let allArgs = field.buildArgs(variables)
        var identity: [String: JSONValue] = [:]
        if let filters = field.connectionFilters {
            for name in filters {
                if CachebayConstants.paginationArgs.contains(name) { continue }
                if let v = allArgs[name] { identity[name] = v }
            }
        }
        let keyPart = field.connectionKey ?? field.fieldName
        let parentPart: String
        if parentId == CachebayConstants.rootID {
            parentPart = "@connection."
        } else {
            parentPart = "@connection.\(parentId)."
        }
        return "\(parentPart)\(keyPart)(\(stableStringify(.object(identity))))"
    }
}
