import Foundation

/// Protocol so we can inject an optimistic replayer without importing Optimistic.
public protocol OptimisticReplayer: Sendable {
    @discardableResult
    func replay(connectionKeys: [CacheKey]) -> Optimistic.ReplayResult

    /// Re-apply pending optimistic layers' entity ops scoped to the
    /// given entity keys. Called from `Documents.normalize` after the
    /// walk completes so server-response writes don't silently clobber
    /// pending optimistic field patches. Symmetric with
    /// `replay(connectionKeys:)` for the entity axis.
    func replayEntityOps(scope entityKeys: Set<CacheKey>)
}

/// Canonical connection merger — Relay-style cursor pagination.
///
/// Merges a just-normalized page record (at `pageKey`) into the canonical
/// connection record (at `@connection.…`). Handles forward (`after`),
/// backward (`before`), and leader (no cursor) paginations, de-duplicates
/// by node identity, maintains a cursor → position index for O(1) cursor
/// lookups, and shallow-merges `pageInfo` + connection-level extras.
public final class Canonical: @unchecked Sendable {
    private let graph: Graph
    private var replayer: OptimisticReplayer?

    public init(graph: Graph, replayer: OptimisticReplayer? = nil) {
        self.graph = graph
        self.replayer = replayer
    }

    public func setReplayer(_ replayer: OptimisticReplayer?) {
        self.replayer = replayer
    }

    /// Merge the freshly-normalized page into canonical.
    public func updateConnection(field: PlanField, parentId: CacheKey, variables: [String: JSONValue], pageKey: CacheKey) {
        let canonicalKey = Keys.buildConnectionCanonicalKey(field: field, parentId: parentId, variables: variables)
        ensureCanonical(canonicalKey)

        guard let page = graph.getRecord(pageKey) else { return }
        let incomingEdgeRefs = page[CachebayConstants.connectionEdgesField]?.refList ?? []

        // Page mode: replace entire canonical with incoming page.
        if field.connectionMode == .page {
            applyPageMode(field: field, canonicalKey: canonicalKey, page: page, incomingEdgeRefs: incomingEdgeRefs)
            stampEdgeTypename(field, canonicalKey)
            replayer?.replay(connectionKeys: [canonicalKey])
            return
        }

        applyInfiniteMode(field: field, canonicalKey: canonicalKey, page: page, incomingEdgeRefs: incomingEdgeRefs, variables: variables)
        stampEdgeTypename(field, canonicalKey)
        replayer?.replay(connectionKeys: [canonicalKey])
    }

    /// Record the schema-derived edge type name on the canonical (merge, so it
    /// survives the page-mode `replaceRecord` above). Lets an optimistic
    /// `insertEdge` give its synthetic edge the authoritative `__typename` even
    /// when the connection is empty (no sibling edge to copy from). Runtime-
    /// compiled plans carry no edge type (no schema) → no stamp → sibling/guess.
    private func stampEdgeTypename(_ field: PlanField, _ canonicalKey: CacheKey) {
        guard let edgeTypename = field.connectionEdgeTypename else { return }
        graph.putRecord(canonicalKey, [CachebayConstants.connectionEdgeTypenameField: .string(edgeTypename)])
    }

    // MARK: - Page mode

    private func applyPageMode(field: PlanField, canonicalKey: CacheKey, page: [String: JSONValue], incomingEdgeRefs: [CacheKey]) {
        let pageInfoRef = page[CachebayConstants.connectionPageInfoField]?.ref
        let pageInfoData = pageInfoRef.flatMap { graph.getRecord($0) } ?? [:]
        let pageInfoKey = "\(canonicalKey).pageInfo"

        graph.putRecord(pageInfoKey, [
            CachebayConstants.typenameField: pageInfoData[CachebayConstants.typenameField] ?? .string(CachebayConstants.connectionPageInfoTypename),
            "startCursor": pageInfoData["startCursor"] ?? .null,
            "endCursor": pageInfoData["endCursor"] ?? .null,
            "hasPreviousPage": .bool(pageInfoData["hasPreviousPage"]?.bool ?? false),
            "hasNextPage": .bool(pageInfoData["hasNextPage"]?.bool ?? false),
        ])

        var record: [String: JSONValue] = [
            CachebayConstants.typenameField: page[CachebayConstants.typenameField] ?? .string(CachebayConstants.connectionTypename),
            CachebayConstants.connectionEdgesField: .refList(incomingEdgeRefs),
            CachebayConstants.connectionPageInfoField: .ref(pageInfoKey),
        ]
        for (k, v) in extras(of: page) {
            record[k] = v
        }
        graph.replaceRecord(canonicalKey, record)
        writeCursorIndex(canonicalKey, buildCursorIndex(incomingEdgeRefs))
        ConnectionIndex.rebuild(graph: graph, canonicalKey: canonicalKey, edgeRefs: incomingEdgeRefs)
    }

    // MARK: - Infinite mode

    private func applyInfiniteMode(
        field: PlanField,
        canonicalKey: CacheKey,
        page: [String: JSONValue],
        incomingEdgeRefs: [CacheKey],
        variables: [String: JSONValue]
    ) {
        let args = field.buildArgs(variables)
        let after = args[CachebayConstants.connectionAfterField]?.string
        let before = args[CachebayConstants.connectionBeforeField]?.string
        let isLeader = (after == nil && before == nil)

        let existing = graph.getRecord(canonicalKey) ?? [:]
        let existingEdges = existing[CachebayConstants.connectionEdgesField]?.refList ?? []
        let existingCursorIndex = readCursorIndex(canonicalKey)

        var prefixEnd = 0
        var suffixStart = 0
        var isPureAppend = false
        var isPurePrepend = false

        if isLeader {
            prefixEnd = 0
            suffixStart = existingEdges.count
        } else if let after {
            let idx = findCursorIndex(existingEdges, after, existingCursorIndex)
            if idx >= 0 {
                prefixEnd = idx + 1
                suffixStart = existingEdges.count
                isPureAppend = idx == existingEdges.count - 1
            } else {
                prefixEnd = existingEdges.count
                suffixStart = existingEdges.count
                isPureAppend = true
            }
        } else if let before {
            let idx = findCursorIndex(existingEdges, before, existingCursorIndex)
            if idx >= 0 {
                prefixEnd = 0
                suffixStart = idx
                isPurePrepend = idx == 0
            } else {
                prefixEnd = 0
                suffixStart = 0
                isPurePrepend = true
            }
        }

        // Merge edges: prefix + incoming (dedup against KEPT existing) + suffix.
        var merged: [CacheKey] = []
        merged.reserveCapacity(prefixEnd + incomingEdgeRefs.count + (existingEdges.count - suffixStart))

        // Dedup against the existing edges that will SURVIVE the merge —
        // i.e. the prefix range + the suffix range. Edges outside that
        // range are about to be discarded by the splice, so deduping
        // incoming against them would incorrectly drop incoming nodes
        // whose ids happened to also be in stale (about-to-be-dropped)
        // edges. In particular, leader mode (prefixEnd=0,
        // suffixStart=existingEdges.count) means no existing is kept,
        // so no dedup runs and incoming lands as-is.
        var existingNodeToEdge: [CacheKey: (index: Int, edgeKey: CacheKey)] = [:]
        if prefixEnd > 0 {
            for i in 0..<prefixEnd {
                let ek = existingEdges[i]
                if let edge = graph.getRecord(ek), let node = edge[CachebayConstants.connectionNodeField]?.ref {
                    existingNodeToEdge[node] = (i, ek)
                }
            }
        }
        if suffixStart < existingEdges.count {
            for i in suffixStart..<existingEdges.count {
                let ek = existingEdges[i]
                if let edge = graph.getRecord(ek), let node = edge[CachebayConstants.connectionNodeField]?.ref {
                    existingNodeToEdge[node] = (i, ek)
                }
            }
        }

        // Collect incoming node keys and refresh edge meta for duplicates.
        var incomingFilteredRefs: [CacheKey] = []
        for ek in incomingEdgeRefs {
            let edge = graph.getRecord(ek) ?? [:]
            guard let nodeKey = edge[CachebayConstants.connectionNodeField]?.ref else {
                incomingFilteredRefs.append(ek)
                continue
            }
            if let dup = existingNodeToEdge[nodeKey] {
                // Refresh edge meta in place on the existing edge record.
                var refreshed: [String: JSONValue] = [:]
                for (k, v) in edge where k != CachebayConstants.typenameField && k != CachebayConstants.connectionNodeField {
                    refreshed[k] = v
                }
                if !refreshed.isEmpty {
                    graph.putRecord(dup.edgeKey, refreshed)
                }
                // Do not insert duplicate.
                continue
            }
            incomingFilteredRefs.append(ek)
        }

        for i in 0..<prefixEnd { merged.append(existingEdges[i]) }
        for ek in incomingFilteredRefs { merged.append(ek) }
        if suffixStart < existingEdges.count {
            for i in suffixStart..<existingEdges.count { merged.append(existingEdges[i]) }
        }

        // Cursor index recomputation (general case fallback for correctness).
        var newCursorIndex: [String: Int] = [:]
        if isPureAppend && !existingCursorIndex.isEmpty && prefixEnd == existingEdges.count {
            newCursorIndex = existingCursorIndex
            var pos = existingEdges.count
            for ek in incomingFilteredRefs {
                if let c = getEdgeCursor(ek) {
                    newCursorIndex[c] = pos
                }
                pos += 1
            }
        } else if isPurePrepend && !existingCursorIndex.isEmpty && suffixStart == 0 {
            let shift = incomingFilteredRefs.count
            for (c, p) in existingCursorIndex { newCursorIndex[c] = p + shift }
            for (i, ek) in incomingFilteredRefs.enumerated() {
                if let c = getEdgeCursor(ek) { newCursorIndex[c] = i }
            }
        } else {
            for (i, ek) in merged.enumerated() {
                if let c = getEdgeCursor(ek) { newCursorIndex[c] = i }
            }
        }
        writeCursorIndex(canonicalKey, newCursorIndex)

        // pageInfo merge.
        let incomingPageInfoRef = page[CachebayConstants.connectionPageInfoField]?.ref
        let incomingPageInfo = incomingPageInfoRef.flatMap { graph.getRecord($0) } ?? [:]
        let existingPageInfoRef = existing[CachebayConstants.connectionPageInfoField]?.ref
        let existingPageInfo = existingPageInfoRef.flatMap { graph.getRecord($0) } ?? [:]

        var pageInfo: [String: JSONValue] = [:]
        pageInfo[CachebayConstants.typenameField] = incomingPageInfo[CachebayConstants.typenameField]
            ?? existingPageInfo[CachebayConstants.typenameField]
            ?? .string(CachebayConstants.connectionPageInfoTypename)
        // Start from existing; apply incoming extras
        for (k, v) in existingPageInfo where k != CachebayConstants.typenameField { pageInfo[k] = v }
        for (k, v) in incomingPageInfo {
            switch k {
            case "hasPreviousPage", "hasNextPage", "startCursor", "endCursor", CachebayConstants.typenameField:
                continue
            default:
                pageInfo[k] = v
            }
        }

        let prefixLen = prefixEnd
        let suffixLen = existingEdges.count - suffixStart

        if prefixLen == 0 {
            // Match cachebay-web's `!!hasPreviousPage`: coerce non-bool
            // values (notably `null`) to `false`. Server payloads that
            // send `hasPreviousPage: null` would otherwise persist as
            // `null` on iOS, while web stores `false`.
            if let hp = incomingPageInfo["hasPreviousPage"] {
                pageInfo["hasPreviousPage"] = .bool(hp.bool ?? false)
            }
            if let sc = incomingPageInfo["startCursor"] { pageInfo["startCursor"] = sc }
        }
        if suffixLen == 0 {
            if let hn = incomingPageInfo["hasNextPage"] {
                pageInfo["hasNextPage"] = .bool(hn.bool ?? false)
            }
            if let ec = incomingPageInfo["endCursor"] { pageInfo["endCursor"] = ec }
        }
        // Infer from first/last edges if still nil.
        if (pageInfo["startCursor"]?.isNull ?? true) && !merged.isEmpty,
           let firstCursor = getEdgeCursor(merged[0]) {
            pageInfo["startCursor"] = .string(firstCursor)
        }
        if (pageInfo["endCursor"]?.isNull ?? true) && !merged.isEmpty,
           let lastCursor = getEdgeCursor(merged[merged.count - 1]) {
            pageInfo["endCursor"] = .string(lastCursor)
        }
        // Default falsy booleans.
        if pageInfo["hasPreviousPage"] == nil { pageInfo["hasPreviousPage"] = .bool(false) }
        if pageInfo["hasNextPage"] == nil { pageInfo["hasNextPage"] = .bool(false) }
        if pageInfo["startCursor"] == nil { pageInfo["startCursor"] = .null }
        if pageInfo["endCursor"] == nil { pageInfo["endCursor"] = .null }

        let pageInfoKey = "\(canonicalKey).pageInfo"
        graph.putRecord(pageInfoKey, pageInfo)

        // Canonical record with merged edges + extras.
        var record: [String: JSONValue] = [
            CachebayConstants.typenameField: page[CachebayConstants.typenameField]
                ?? existing[CachebayConstants.typenameField]
                ?? .string(CachebayConstants.connectionTypename),
            CachebayConstants.connectionEdgesField: .refList(merged),
            CachebayConstants.connectionPageInfoField: .ref(pageInfoKey),
        ]
        for (k, v) in extras(of: existing) { record[k] = v }
        for (k, v) in extras(of: page) { record[k] = v }
        graph.replaceRecord(canonicalKey, record)
        ConnectionIndex.rebuild(graph: graph, canonicalKey: canonicalKey, edgeRefs: merged)
    }

    // MARK: - Helpers

    private func extras(of connection: [String: JSONValue]) -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = []
        for (k, v) in connection {
            switch k {
            case CachebayConstants.connectionEdgesField,
                 CachebayConstants.connectionPageInfoField,
                 CachebayConstants.typenameField: continue
            default: out.append((k, v))
            }
        }
        return out
    }

    func ensureCanonical(_ canonicalKey: CacheKey) {
        if graph.hasRecord(canonicalKey) { return }
        let pageInfoKey = "\(canonicalKey).pageInfo"
        graph.putRecord(pageInfoKey, [
            CachebayConstants.typenameField: .string(CachebayConstants.connectionPageInfoTypename),
            "startCursor": .null,
            "endCursor": .null,
            "hasPreviousPage": .bool(false),
            "hasNextPage": .bool(false),
        ])
        graph.putRecord(canonicalKey, [
            CachebayConstants.typenameField: .string(CachebayConstants.connectionTypename),
            CachebayConstants.connectionEdgesField: .refList([]),
            CachebayConstants.connectionPageInfoField: .ref(pageInfoKey),
        ])
        writeCursorIndex(canonicalKey, [:])
        ConnectionIndex.clear(graph: graph, canonicalKey: canonicalKey)
    }

    private func cursorIndexKey(_ canonicalKey: CacheKey) -> CacheKey {
        "\(canonicalKey)::cursorIndex"
    }

    func readCursorIndex(_ canonicalKey: CacheKey) -> [String: Int] {
        guard let rec = graph.getRecord(cursorIndexKey(canonicalKey)) else { return [:] }
        var out: [String: Int] = [:]
        out.reserveCapacity(rec.count)
        for (k, v) in rec {
            if case .int(let i) = v { out[k] = Int(i) }
        }
        return out
    }

    func writeCursorIndex(_ canonicalKey: CacheKey, _ index: [String: Int]) {
        var rec: [String: JSONValue] = [:]
        rec.reserveCapacity(index.count)
        for (k, v) in index { rec[k] = .int(Int64(v)) }
        graph.replaceRecord(cursorIndexKey(canonicalKey), rec)
    }

    private func getEdgeCursor(_ edgeKey: CacheKey) -> String? {
        return graph.getField(edgeKey, "cursor")?.string
    }

    private func findCursorIndex(_ edges: [CacheKey], _ cursor: String, _ index: [String: Int]) -> Int {
        if let pos = index[cursor], pos < edges.count { return pos }
        for (i, ek) in edges.enumerated() {
            if getEdgeCursor(ek) == cursor { return i }
        }
        return -1
    }

    private func buildCursorIndex(_ edges: [CacheKey]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, ek) in edges.enumerated() {
            if let c = getEdgeCursor(ek) { out[c] = i }
        }
        return out
    }
}
