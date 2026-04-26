import Foundation

/// Fingerprinting for PlanFields and root plans.
/// Mirrors `src/compiler/fingerprint.ts` from cachebay-web.
enum Fingerprint {
    /// Stable fingerprint for a single PlanField subtree. Order-insensitive
    /// over children (sorted by responseKey, then fieldName).
    static func fieldSelId(
        responseKey: String,
        fieldName: String,
        typeCondition: String?,
        isConnection: Bool,
        argNames: [String],
        children: [PlanField]
    ) -> String {
        var parts: [String] = [responseKey, fieldName]
        if let tc = typeCondition { parts.append("@\(tc)") }
        if isConnection { parts.append("@connection") }
        if !argNames.isEmpty {
            parts.append("(\(argNames.sorted().joined(separator: ",")))")
        }
        if !children.isEmpty {
            let sorted = children.sorted { a, b in
                if a.responseKey != b.responseKey { return a.responseKey < b.responseKey }
                return a.fieldName < b.fieldName
            }
            let childFps = sorted.map(\.selId)
            parts.append("{\(childFps.joined(separator: ","))}")
        }
        return parts.joined(separator: ":")
    }

    /// Stable fingerprint for the root plan. Includes operation + rootTypename.
    static func rootFingerprint(_ root: [PlanField], operation: String, rootTypename: String) -> String {
        let sorted = root.sorted { a, b in
            if a.responseKey != b.responseKey { return a.responseKey < b.responseKey }
            return a.fieldName < b.fieldName
        }
        let fps = sorted.map(\.selId)
        return "\(operation):\(rootTypename):[\(fps.joined(separator: ","))]"
    }
}
