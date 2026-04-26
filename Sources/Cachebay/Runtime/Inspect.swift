import Foundation

/// Debug inspection API. Mirrors `src/core/inspect.ts` in cachebay-web.
public final class Inspect: @unchecked Sendable {
    private let graph: Graph

    public init(graph: Graph) {
        self.graph = graph
    }

    public func getRecord(_ id: CacheKey) -> [String: JSONValue]? {
        graph.getRecord(id)
    }

    /// Enumerate entity record ids (excludes the root, page records, edge records).
    /// Optional typename filter.
    public func getEntityKeys(typename: String? = nil) -> [CacheKey] {
        var out: [CacheKey] = []
        for k in graph.keysList() {
            if isRootRecord(k) || isPageRecord(k) || isEdgeRecord(k) { continue }
            if let typename, !k.hasPrefix("\(typename):") { continue }
            out.append(k)
        }
        return out
    }

    /// Parent selector for connection lookups.
    public enum ParentSelector: Sendable {
        case root
        case entity(String)
        case entityObject(typename: String, id: String)
    }

    /// Return canonical `@connection.…` keys for pages matching the filter.
    public func getConnectionKeys(parent: ParentSelector? = nil, key: String? = nil, argsFilter: (@Sendable (_ rawArgs: String) -> Bool)? = nil) -> [CacheKey] {
        var out: Set<CacheKey> = []
        for k in graph.keysList() {
            guard isPageRecord(k) else { continue }
            if let parent, !isPageUnderParent(k, parent: parent) { continue }
            if let key, fieldOf(k) != key { continue }
            let raw = argsOf(k)
            if let argsFilter, !argsFilter(raw) { continue }

            let filters = parseFilters(raw)
            let parenIdx = k.firstIndex(of: "(")
            let end = parenIdx ?? k.endIndex
            let lastDot = k[..<end].lastIndex(of: ".") ?? k.startIndex
            let hasParent = k.distance(from: k.startIndex, to: lastDot) > 1
            let parentStr = hasParent ? String(k[k.index(k.startIndex, offsetBy: 2)..<lastDot]) : CachebayConstants.rootID
            let fieldName = String(k[k.index(after: lastDot)..<end])

            let filterKeys = Array(filters.keys)
            let stringify: @Sendable ([String: JSONValue]) -> String = { vars in
                let mask = filterKeys.sorted()
                var parts: [String] = []
                for kk in mask { if let v = vars[kk] { parts.append("\"\(kk)\":" + stableStringify(v)) } }
                return "{" + parts.joined(separator: ",") + "}"
            }
            let field = PlanField(
                responseKey: fieldName, fieldName: fieldName,
                selectionSet: nil, selectionMap: nil, typeCondition: nil,
                expectedArgNames: filterKeys,
                buildArgs: { _ in filters },
                stringifyArgs: stringify,
                isConnection: true, connectionKey: fieldName, connectionFilters: filterKeys,
                connectionMode: nil, pageArgs: nil, selId: ""
            )
            out.insert(Keys.buildConnectionCanonicalKey(field: field, parentId: parentStr, variables: filters))
        }
        return Array(out)
    }

    // MARK: - helpers

    private func isRootRecord(_ id: CacheKey) -> Bool { id == CachebayConstants.rootID }
    private func isEdgeRecord(_ id: CacheKey) -> Bool { id.contains(".edges.") }
    private func isPageRecord(_ id: CacheKey) -> Bool { id.hasPrefix("@.") && !isEdgeRecord(id) }

    private func isPageUnderParent(_ pageKey: CacheKey, parent: ParentSelector) -> Bool {
        switch parent {
        case .root:
            // root page: `@.<field>(...)` → last '.' is exactly at index 1.
            guard let paren = pageKey.firstIndex(of: "(") else {
                return pageKey.distance(from: pageKey.startIndex, to: pageKey.lastIndex(of: ".") ?? pageKey.startIndex) == 1
            }
            let head = pageKey[..<paren]
            guard let lastDot = head.lastIndex(of: ".") else { return false }
            return pageKey.distance(from: pageKey.startIndex, to: lastDot) == 1
        case .entity(let e):
            return pageKey.hasPrefix("@.\(e).")
        case .entityObject(let typename, let id):
            return pageKey.hasPrefix("@.\(typename):\(id).")
        }
    }

    private func fieldOf(_ pageKey: CacheKey) -> String? {
        let end = pageKey.firstIndex(of: "(") ?? pageKey.endIndex
        guard let dot = pageKey[..<end].lastIndex(of: ".") else { return nil }
        return String(pageKey[pageKey.index(after: dot)..<end])
    }

    private func argsOf(_ pageKey: CacheKey) -> String {
        guard let open = pageKey.firstIndex(of: "(") else { return "" }
        guard let close = pageKey.lastIndex(of: ")"), close > open else { return "" }
        return String(pageKey[pageKey.index(after: open)..<close])
    }

    private func parseFilters(_ raw: String) -> [String: JSONValue] {
        if raw.isEmpty { return [:] }
        guard let data = raw.data(using: .utf8),
              case .object(let obj) = (try? JSONValue.from(json: data)) ?? .null
        else { return [:] }
        var out: [String: JSONValue] = [:]
        for (k, v) in obj where !CachebayConstants.paginationArgs.contains(k) {
            out[k] = v
        }
        return out
    }
}
