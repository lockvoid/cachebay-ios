import Foundation
import os

public enum MaterializeSource: Hashable, Sendable {
    case canonical
    case strict
    case none
}

public struct MaterializeResult: Sendable {
    public var data: JSONValue
    public var fingerprints: JSONValue
    public var dependencies: Set<CacheKey>
    public var source: MaterializeSource
    public var strictOK: Bool
    public var canonicalOK: Bool
    public var strictSignature: String?
    public var canonicalSignature: String?
    public var hot: Bool
}

public struct MaterializeOptions: Sendable {
    public var canonical: Bool = true
    public var rootId: CacheKey? = nil
    public var fingerprint: Bool = true
    public var preferCache: Bool = true
    public var updateCache: Bool = false

    public init(canonical: Bool = true, rootId: CacheKey? = nil, fingerprint: Bool = true, preferCache: Bool = true, updateCache: Bool = false) {
        self.canonical = canonical
        self.rootId = rootId
        self.fingerprint = fingerprint
        self.preferCache = preferCache
        self.updateCache = updateCache
    }
}

/// Documents subsystem — normalize (response → graph) and materialize (graph → response).
///
/// The heavy work of cachebay-web `src/core/documents.ts` lives here.
/// Ported behavior:
/// - normalize handles scalars, objects (entity / inline container), connection
///   fields (with page records), arrays (entity list / connection edges),
///   nested selections, and null vs undefined linkage semantics.
/// - materialize reads `@` root or an entity rootId, walks the plan to
///   reconstruct the response shape with a parallel fingerprint tree used
///   by recycleSnapshots for identity-preserving watcher emissions.
public final class Documents: @unchecked Sendable {
    private let graph: Graph
    private let planner: Planner
    private let canonical: Canonical
    private let logger: Logger?

    private let lock = NSLock()
    private var materializeCache: [String: MaterializeResult] = [:]

    public init(graph: Graph, planner: Planner, canonical: Canonical, logger: Logger? = nil) {
        self.graph = graph
        self.planner = planner
        self.canonical = canonical
        self.logger = logger
    }

    // MARK: - Normalize

    public func normalize(plan: CachePlan, variables: [String: JSONValue], data: JSONValue, rootId: CacheKey? = nil) {
        let startId = rootId ?? CachebayConstants.rootID
        let shouldLink = (startId != CachebayConstants.rootID) || (plan.operation == .query)
        let isRoot = startId == CachebayConstants.rootID || startId.hasPrefix("@mutation.") || startId.hasPrefix("@subscription.")

        if isRoot {
            graph.putRecord(startId, [
                CachebayConstants.idField: .string(startId),
                CachebayConstants.typenameField: .string(startId),
            ])
        }

        var pendingPages: [PendingPage] = []

        let initialFrame = Frame(
            parentId: startId,
            fieldsMap: plan.rootSelectionMap,
            insideConnection: false,
            pageKey: nil
        )

        if case .object(let obj) = data {
            normalizeObject(obj, frame: initialFrame, plan: plan, variables: variables, shouldLink: shouldLink, pendingPages: &pendingPages)
        }

        for p in pendingPages {
            canonical.updateConnection(field: p.field, parentId: p.parentId, variables: variables, pageKey: p.pageKey)
        }
    }

    private struct Frame {
        let parentId: CacheKey
        let fieldsMap: [String: PlanField]
        let insideConnection: Bool
        let pageKey: CacheKey?
    }

    private struct PendingPage {
        let field: PlanField
        let parentId: CacheKey
        let pageKey: CacheKey
    }

    private func normalizeObject(
        _ obj: [String: JSONValue],
        frame: Frame,
        plan: CachePlan,
        variables: [String: JSONValue],
        shouldLink: Bool,
        pendingPages: inout [PendingPage]
    ) {
        for (responseKey, value) in obj {
            let field = frame.fieldsMap[responseKey]
            normalizeValue(value, responseKey: responseKey, field: field, frame: frame, plan: plan, variables: variables, shouldLink: shouldLink, pendingPages: &pendingPages)
        }
    }

    private func normalizeValue(
        _ value: JSONValue,
        responseKey: String,
        field: PlanField?,
        frame: Frame,
        plan: CachePlan,
        variables: [String: JSONValue],
        shouldLink: Bool,
        pendingPages: inout [PendingPage]
    ) {
        // Arrays
        if case .array(let arr) = value {
            normalizeArray(arr, responseKey: responseKey, field: field, frame: frame, plan: plan, variables: variables, shouldLink: shouldLink, pendingPages: &pendingPages)
            return
        }

        // Explicit null for a field with a selection set → persist as null link.
        if case .null = value, let field, field.selectionSet != nil {
            let fieldKey = Keys.buildFieldKey(field: field, variables: variables)
            graph.putRecord(frame.parentId, [fieldKey: .null])
            return
        }

        if case .object(let obj) = value {
            guard let field else { return }

            if field.selectionSet == nil {
                writeScalar(frame.parentId, field, value: value, variables: variables)
                return
            }

            if field.isConnection {
                normalizeConnection(obj, field: field, frame: frame, plan: plan, variables: variables, shouldLink: shouldLink, pendingPages: &pendingPages)
                return
            }

            if normalizeEntityObject(obj, field: field, frame: frame, plan: plan, variables: variables, shouldLink: shouldLink, pendingPages: &pendingPages) {
                return
            }

            normalizeInlineContainer(obj, field: field, frame: frame, plan: plan, variables: variables, shouldLink: shouldLink, pendingPages: &pendingPages)
            return
        }

        // Scalar on a scalar field.
        if let field, field.selectionSet == nil {
            writeScalar(frame.parentId, field, value: value, variables: variables)
        }
    }

    private func normalizeArray(
        _ arr: [JSONValue],
        responseKey: String,
        field: PlanField?,
        frame: Frame,
        plan: CachePlan,
        variables: [String: JSONValue],
        shouldLink: Bool,
        pendingPages: inout [PendingPage]
    ) {
        // Edges array within a connection page.
        if frame.insideConnection, responseKey == CachebayConstants.connectionEdgesField, let pageKey = frame.pageKey {
            normalizeEdgesArray(pageKey: pageKey, edges: arr, edgesField: field, plan: plan, variables: variables, pendingPages: &pendingPages)
            return
        }

        guard let field else { return }

        if field.selectionSet != nil {
            normalizeArrayOfSelections(arr, field: field, frame: frame, plan: plan, variables: variables, pendingPages: &pendingPages)
        } else {
            let fieldKey = Keys.buildFieldKey(field: field, variables: variables)
            graph.putRecord(frame.parentId, [fieldKey: .array(arr)])
        }
    }

    private func normalizeEdgesArray(
        pageKey: CacheKey,
        edges: [JSONValue],
        edgesField: PlanField?,
        plan: CachePlan,
        variables: [String: JSONValue],
        pendingPages: inout [PendingPage]
    ) {
        var refs: [CacheKey] = []
        refs.reserveCapacity(edges.count)
        for i in 0..<edges.count {
            refs.append("\(pageKey).edges.\(i)")
        }
        graph.putRecord(pageKey, [CachebayConstants.connectionEdgesField: .refList(refs)])

        guard let edgesField, edgesField.selectionSet != nil else { return }
        let edgesChildMap = edgesField.selectionMap ?? [:]

        for (idx, edgeVal) in edges.enumerated() {
            let edgeKey = "\(pageKey).edges.\(idx)"
            guard case .object(let edgeObj) = edgeVal else {
                graph.putRecord(edgeKey, [:])
                continue
            }
            var edgePatch: [String: JSONValue] = [:]
            if let tn = edgeObj[CachebayConstants.typenameField] {
                edgePatch[CachebayConstants.typenameField] = tn
            }
            if let nodeVal = edgeObj[CachebayConstants.connectionNodeField], case .object(let nodeObj) = nodeVal {
                if let nodeKey = graph.identify(nodeObj) {
                    edgePatch[CachebayConstants.connectionNodeField] = .ref(nodeKey)
                }
            }
            graph.putRecord(edgeKey, edgePatch)

            let edgeFrame = Frame(parentId: edgeKey, fieldsMap: edgesChildMap, insideConnection: true, pageKey: pageKey)
            normalizeObject(edgeObj, frame: edgeFrame, plan: plan, variables: variables, shouldLink: true, pendingPages: &pendingPages)
        }
    }

    private func normalizeConnection(
        _ obj: [String: JSONValue],
        field: PlanField,
        frame: Frame,
        plan: CachePlan,
        variables: [String: JSONValue],
        shouldLink: Bool,
        pendingPages: inout [PendingPage]
    ) {
        let pageKey = Keys.buildConnectionKey(field: field, parentId: frame.parentId, variables: variables)
        let fieldKey = Keys.buildFieldKey(field: field, variables: variables)

        // Base page record: __typename + connection-level scalar/extras.
        var pageRecord: [String: JSONValue] = [:]
        if let tn = obj[CachebayConstants.typenameField] { pageRecord[CachebayConstants.typenameField] = tn }
        for (k, v) in obj {
            switch k {
            case CachebayConstants.typenameField,
                 CachebayConstants.connectionEdgesField,
                 CachebayConstants.connectionPageInfoField: continue
            default:
                // Inline scalar/array/inline object — stored directly.
                if case .object(let o) = v, o[CachebayConstants.typenameField] == nil {
                    pageRecord[k] = v
                } else if case .object = v {
                    // Object with typename; fall through and let plan-aware normalize handle it later.
                    continue
                } else {
                    pageRecord[k] = v
                }
            }
        }
        graph.putRecord(pageKey, pageRecord)

        if shouldLink {
            graph.putRecord(frame.parentId, [fieldKey: .ref(pageKey)])
            pendingPages.append(PendingPage(field: field, parentId: frame.parentId, pageKey: pageKey))
        }

        // pageInfo
        if let pageInfoVal = obj[CachebayConstants.connectionPageInfoField], case .object(let pageInfoObj) = pageInfoVal {
            let pageInfoKey = "\(pageKey).pageInfo"
            graph.putRecord(pageKey, [CachebayConstants.connectionPageInfoField: .ref(pageInfoKey)])
            graph.putRecord(pageInfoKey, pageInfoObj)
        }

        // Children (edges + nested selections on connection itself).
        let connectionFieldsMap = field.selectionMap ?? [:]
        let nextFrame = Frame(parentId: pageKey, fieldsMap: connectionFieldsMap, insideConnection: true, pageKey: pageKey)
        normalizeObject(obj, frame: nextFrame, plan: plan, variables: variables, shouldLink: shouldLink, pendingPages: &pendingPages)
    }

    private func normalizeEntityObject(
        _ obj: [String: JSONValue],
        field: PlanField,
        frame: Frame,
        plan: CachePlan,
        variables: [String: JSONValue],
        shouldLink: Bool,
        pendingPages: inout [PendingPage]
    ) -> Bool {
        guard let rootId = graph.identify(obj) else { return false }

        var patch: [String: JSONValue] = [:]
        if let tn = obj[CachebayConstants.typenameField] { patch[CachebayConstants.typenameField] = tn }
        graph.putRecord(rootId, patch)

        let isNode = field.responseKey == CachebayConstants.connectionNodeField
        if !(frame.insideConnection && isNode) {
            linkTo(frame.parentId, field: field, targetId: rootId, shouldLink: shouldLink, variables: variables)
        }

        let childMap = field.selectionMap ?? [:]
        let childrenFrame = Frame(
            parentId: rootId,
            fieldsMap: childMap,
            insideConnection: isNode ? false : frame.insideConnection,
            pageKey: isNode ? nil : frame.pageKey
        )
        normalizeObject(obj, frame: childrenFrame, plan: plan, variables: variables, shouldLink: true, pendingPages: &pendingPages)
        return true
    }

    private func normalizeInlineContainer(
        _ obj: [String: JSONValue],
        field: PlanField,
        frame: Frame,
        plan: CachePlan,
        variables: [String: JSONValue],
        shouldLink: Bool,
        pendingPages: inout [PendingPage]
    ) {
        let containerFieldKey = Keys.buildFieldKey(field: field, variables: variables)
        let containerKey = "\(frame.parentId).\(containerFieldKey)"
        var base: [String: JSONValue] = [:]
        if let tn = obj[CachebayConstants.typenameField] { base[CachebayConstants.typenameField] = tn }
        graph.putRecord(containerKey, base)
        if shouldLink {
            graph.putRecord(frame.parentId, [containerFieldKey: .ref(containerKey)])
        }
        if frame.insideConnection, containerFieldKey == CachebayConstants.connectionPageInfoField, let pageKey = frame.pageKey {
            graph.putRecord(pageKey, [CachebayConstants.connectionPageInfoField: .ref(containerKey)])
        }
        let childMap = field.selectionMap ?? [:]
        let nextFrame = Frame(parentId: containerKey, fieldsMap: childMap, insideConnection: frame.insideConnection, pageKey: frame.pageKey)
        normalizeObject(obj, frame: nextFrame, plan: plan, variables: variables, shouldLink: shouldLink, pendingPages: &pendingPages)
    }

    private func normalizeArrayOfSelections(
        _ arr: [JSONValue],
        field: PlanField,
        frame: Frame,
        plan: CachePlan,
        variables: [String: JSONValue],
        pendingPages: inout [PendingPage]
    ) {
        let fieldKey = Keys.buildFieldKey(field: field, variables: variables)
        let baseKey = "\(frame.parentId).\(fieldKey)"

        var refs: [CacheKey] = []
        refs.reserveCapacity(arr.count)
        for (i, item) in arr.enumerated() {
            let rootId: CacheKey?
            if case .object(let o) = item {
                rootId = graph.identify(o)
            } else {
                rootId = nil
            }
            let itemKey = rootId ?? "\(baseKey).\(i)"
            if case .object(let o) = item {
                var patch: [String: JSONValue] = [:]
                if let tn = o[CachebayConstants.typenameField] { patch[CachebayConstants.typenameField] = tn }
                graph.putRecord(itemKey, patch)
            }
            refs.append(itemKey)
        }
        graph.putRecord(frame.parentId, [fieldKey: .refList(refs)])

        let childMap = field.selectionMap ?? [:]
        for (i, item) in arr.enumerated() {
            guard case .object(let o) = item else { continue }
            let rootId = graph.identify(o)
            let itemKey = rootId ?? "\(baseKey).\(i)"
            let itemFrame = Frame(parentId: itemKey, fieldsMap: childMap, insideConnection: false, pageKey: baseKey)
            normalizeObject(o, frame: itemFrame, plan: plan, variables: variables, shouldLink: true, pendingPages: &pendingPages)
        }
    }

    private func writeScalar(_ parentId: CacheKey, _ field: PlanField, value: JSONValue, variables: [String: JSONValue]) {
        let fieldKey = Keys.buildFieldKey(field: field, variables: variables)
        graph.putRecord(parentId, [fieldKey: value])
    }

    private func linkTo(_ parentId: CacheKey, field: PlanField, targetId: CacheKey, shouldLink: Bool, variables: [String: JSONValue]) {
        if !shouldLink { return }
        let fieldKey = Keys.buildFieldKey(field: field, variables: variables)
        graph.putRecord(parentId, [fieldKey: .ref(targetId)])
    }

    // MARK: - Materialize

    public func materialize(plan: CachePlan, variables: [String: JSONValue], options: MaterializeOptions = .init()) -> MaterializeResult {
        let strictSig = plan.makeSignature(canonical: false, variables: variables)
        let canonicalSig = options.canonical ? plan.makeSignature(canonical: true, variables: variables) : nil
        let cacheKey = makeMaterializeCacheKey(signature: options.canonical ? canonicalSig! : strictSig, fingerprint: options.fingerprint, rootId: options.rootId)

        if options.preferCache {
            lock.lock()
            if var hit = materializeCache[cacheKey] {
                hit.hot = true
                lock.unlock()
                return hit
            }
            lock.unlock()
        }

        graph.flush()

        var context = MaterializeContext(
            graph: graph,
            variables: variables,
            canonical: options.canonical,
            fingerprint: options.fingerprint,
            logger: logger
        )

        var data: [String: JSONValue] = [:]
        var fingerprints: [String: JSONValue] = [:]

        let isRootId = options.rootId == nil
            || options.rootId == CachebayConstants.rootID
            || (options.rootId?.hasPrefix("@mutation.") ?? false)
            || (options.rootId?.hasPrefix("@subscription.") ?? false)

        if let rootId = options.rootId, !isRootId {
            // Fragment / entity materialization.
            let synthetic = PlanField(
                responseKey: "", fieldName: "",
                selectionSet: plan.root, selectionMap: plan.rootSelectionMap,
                typeCondition: nil, expectedArgNames: [],
                buildArgs: { _ in [:] }, stringifyArgs: { _ in "" },
                isConnection: false, connectionKey: nil, connectionFilters: nil,
                connectionMode: nil, pageArgs: nil, selId: ""
            )
            context.readEntity(rootId, field: synthetic, into: &data, fingerprint: &fingerprints, path: rootId)
        } else {
            let rootKey = options.rootId ?? CachebayConstants.rootID
            let rootRecord = graph.getRecord(rootKey) ?? [:]
            for field in plan.root {
                let path = "\(rootKey).\(field.responseKey)"
                if field.isConnection {
                    var childFp: [String: JSONValue] = [:]
                    context.readConnection(parentId: rootKey, field: field, out: &data, outKey: field.responseKey, fpOut: &childFp, path: path)
                    if options.fingerprint { fingerprints[field.responseKey] = .object(childFp) }
                    continue
                }

                if let children = field.selectionSet, !children.isEmpty {
                    let fieldKey = Keys.buildFieldKey(field: field, variables: variables)
                    context.dependencies.insert("\(rootKey).\(fieldKey)")
                    let link = rootRecord[fieldKey]
                    switch link {
                    case .none, .some(.undefined):
                        data[field.responseKey] = .undefined
                        context.strictOK = false
                        context.canonicalOK = false
                    case .some(.null):
                        data[field.responseKey] = .null
                    case .some(.ref(let r)):
                        var childOut: [String: JSONValue] = [:]
                        var childFp: [String: JSONValue] = [:]
                        context.readEntity(r, field: field, into: &childOut, fingerprint: &childFp, path: path)
                        data[field.responseKey] = .object(childOut)
                        if options.fingerprint { fingerprints[field.responseKey] = .object(childFp) }
                    case .some(.refList(let refs)):
                        var items: [JSONValue] = []
                        var fpItems: [JSONValue] = []
                        items.reserveCapacity(refs.count)
                        fpItems.reserveCapacity(refs.count)
                        for (i, r) in refs.enumerated() {
                            var childOut: [String: JSONValue] = [:]
                            var childFp: [String: JSONValue] = [:]
                            context.readEntity(r, field: field, into: &childOut, fingerprint: &childFp, path: "\(path)[\(i)]")
                            items.append(.object(childOut))
                            fpItems.append(.object(childFp))
                        }
                        data[field.responseKey] = .array(items)
                        if options.fingerprint { fingerprints[field.responseKey] = .array(fpItems) }
                    default:
                        data[field.responseKey] = .undefined
                        context.strictOK = false
                        context.canonicalOK = false
                    }
                } else {
                    context.readScalar(rootRecord, field: field, parentId: rootKey, into: &data, outKey: field.responseKey, path: path)
                }
            }
        }

        let requestedOK = options.canonical ? context.canonicalOK : context.strictOK
        // Match cachebay-web: aggregate root-level field fingerprints
        // into `fingerprints[__version]` for query/mutation/subscription
        // reads. Fragment reads already get a `__version` because
        // `readEntity` writes one onto its `fpOut` directly. Without
        // this top-level aggregation, a watcher's `recycleSnapshots`
        // can't short-circuit via root identity and may emit duplicate
        // data on every dep change.
        if options.fingerprint, requestedOK, options.rootId == nil || options.rootId == CachebayConstants.rootID || (options.rootId?.hasPrefix("@mutation.") ?? false) || (options.rootId?.hasPrefix("@subscription.") ?? false) {
            var rootFps: [UInt32] = []
            for field in plan.root {
                if let fp = fingerprints[field.responseKey] {
                    if case .object(let o) = fp, case .int(let v) = o[CachebayConstants.fingerprintKey] ?? .undefined {
                        rootFps.append(UInt32(truncatingIfNeeded: v))
                    } else if case .array(let arr) = fp {
                        for item in arr {
                            if case .object(let o) = item, case .int(let v) = o[CachebayConstants.fingerprintKey] ?? .undefined {
                                rootFps.append(UInt32(truncatingIfNeeded: v))
                            }
                        }
                    }
                }
            }
            if !rootFps.isEmpty {
                fingerprints[CachebayConstants.fingerprintKey] = .int(Int64(fingerprintNodes(0, rootFps)))
            }
        }
        let result: MaterializeResult = !requestedOK
            ? MaterializeResult(
                data: .undefined, fingerprints: .undefined,
                dependencies: context.dependencies, source: .none,
                strictOK: context.strictOK, canonicalOK: context.canonicalOK,
                strictSignature: strictSig, canonicalSignature: canonicalSig, hot: false
            )
            : MaterializeResult(
                data: .object(data), fingerprints: .object(fingerprints),
                dependencies: context.dependencies,
                source: options.canonical ? .canonical : .strict,
                strictOK: context.strictOK, canonicalOK: context.canonicalOK,
                strictSignature: strictSig, canonicalSignature: canonicalSig, hot: false
            )

        if options.updateCache {
            lock.lock()
            materializeCache[cacheKey] = result
            lock.unlock()
        }
        return result
    }

    public func invalidate(plan: CachePlan, variables: [String: JSONValue], canonical: Bool = true, rootId: CacheKey? = nil, fingerprint: Bool = true) {
        let signature = plan.makeSignature(canonical: canonical, variables: variables)
        let cacheKey = makeMaterializeCacheKey(signature: signature, fingerprint: fingerprint, rootId: rootId)
        lock.lock()
        materializeCache.removeValue(forKey: cacheKey)
        lock.unlock()
    }

    public func evictAll() {
        lock.lock()
        materializeCache.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func makeMaterializeCacheKey(signature: String, fingerprint: Bool, rootId: CacheKey?) -> String {
        let fp = fingerprint ? "f" : "n"
        if let rootId { return "entity:\(rootId)|\(fp)|\(signature)" }
        return "\(fp)|\(signature)"
    }
}

// MARK: - Materialize context

struct MaterializeContext {
    let graph: Graph
    let variables: [String: JSONValue]
    let canonical: Bool
    let fingerprint: Bool
    let logger: Logger?

    var strictOK: Bool = true
    var canonicalOK: Bool = true
    var dependencies: Set<CacheKey> = []

    mutating func readEntity(_ id: CacheKey, field: PlanField, into out: inout [String: JSONValue], fingerprint fpOut: inout [String: JSONValue], path: String) {
        dependencies.insert(id)
        guard let record = graph.getRecord(id) else {
            strictOK = false
            canonicalOK = false
            return
        }

        if let tn = record[CachebayConstants.typenameField] {
            out[CachebayConstants.typenameField] = tn
        }
        let runtimeType = record[CachebayConstants.typenameField]?.string

        guard let children = field.selectionSet else { return }
        var childFingerprints: [UInt32] = []

        for child in children {
            let outKey = child.responseKey
            if !selectionApplies(child, runtimeType: runtimeType) { continue }

            if child.isConnection {
                var childFp: [String: JSONValue] = [:]
                var localOut: [String: JSONValue] = out
                readConnection(parentId: id, field: child, out: &localOut, outKey: outKey, fpOut: &childFp, path: "\(path).\(outKey)")
                out = localOut
                if fingerprint { fpOut[outKey] = .object(childFp) }
                if case .int(let v) = childFp[CachebayConstants.fingerprintKey] ?? .undefined {
                    childFingerprints.append(UInt32(truncatingIfNeeded: v))
                }
                continue
            }

            if let childChildren = child.selectionSet, !childChildren.isEmpty {
                let storeKey = Keys.buildFieldKey(field: child, variables: variables)
                let link = record[storeKey]
                switch link {
                case .some(.refList(let refs)):
                    var items: [JSONValue] = []
                    var fpItems: [JSONValue] = []
                    var arrayFingerprints: [UInt32] = []
                    items.reserveCapacity(refs.count)
                    fpItems.reserveCapacity(refs.count)
                    for (j, r) in refs.enumerated() {
                        var childOut: [String: JSONValue] = [:]
                        var childFp: [String: JSONValue] = [:]
                        readEntity(r, field: child, into: &childOut, fingerprint: &childFp, path: "\(path).\(outKey)[\(j)]")
                        items.append(.object(childOut))
                        fpItems.append(.object(childFp))
                        if case .int(let v) = childFp[CachebayConstants.fingerprintKey] ?? .undefined {
                            arrayFingerprints.append(UInt32(truncatingIfNeeded: v))
                        }
                    }
                    out[outKey] = .array(items)
                    if fingerprint {
                        var arrFp: [String: JSONValue] = [:]
                        if !arrayFingerprints.isEmpty {
                            let a = fingerprintNodes(0, arrayFingerprints)
                            arrFp[CachebayConstants.fingerprintKey] = .int(Int64(a))
                            childFingerprints.append(a)
                        }
                        // Still emit the array of per-item fingerprints so recycle can use them.
                        fpOut[outKey] = .array(fpItems)
                    }
                case .some(.ref(let r)):
                    var childOut: [String: JSONValue] = [:]
                    var childFp: [String: JSONValue] = [:]
                    readEntity(r, field: child, into: &childOut, fingerprint: &childFp, path: "\(path).\(outKey)")
                    out[outKey] = .object(childOut)
                    if fingerprint { fpOut[outKey] = .object(childFp) }
                    if case .int(let v) = childFp[CachebayConstants.fingerprintKey] ?? .undefined {
                        childFingerprints.append(UInt32(truncatingIfNeeded: v))
                    }
                case .some(.null):
                    out[outKey] = .null
                case .none, .some(.undefined):
                    out[outKey] = .undefined
                    strictOK = false; canonicalOK = false
                    logger?.warning("[Cachebay] materialize miss: record \(id, privacy: .public) has no field '\(storeKey, privacy: .public)' (selection set required) — likely a mutation/fragment wrote a partial entity that doesn't satisfy a watching query's selection set")
                default:
                    out[outKey] = .undefined
                    strictOK = false; canonicalOK = false
                    logger?.warning("[Cachebay] materialize miss: record \(id, privacy: .public) field '\(storeKey, privacy: .public)' has unexpected link shape — selection set requires ref/refList/null")
                }
                continue
            }

            readScalar(record, field: child, parentId: id, into: &out, outKey: outKey, path: "\(path).\(outKey)")
        }

        let version = graph.version(id)
        let finalFp = childFingerprints.isEmpty ? version : fingerprintNodes(version, childFingerprints)
        if fingerprint { fpOut[CachebayConstants.fingerprintKey] = .int(Int64(finalFp)) }
    }

    mutating func readConnection(parentId: CacheKey, field: PlanField, out: inout [String: JSONValue], outKey: String, fpOut: inout [String: JSONValue], path: String) {
        // Mirror cachebay-web: track BOTH OK flags (canonical + strict)
        // regardless of the read mode. Reading canonical mode must still
        // flip `strictOK = false` if the per-page strict record is
        // absent — and vice versa — so `cacheFirst` policy correctly
        // detects "we don't have the exact page" even when the
        // canonical merger has data.
        let baseIsCanonical = canonical
        let baseKey = baseIsCanonical
            ? Keys.buildConnectionCanonicalKey(field: field, parentId: parentId, variables: variables)
            : Keys.buildConnectionKey(field: field, parentId: parentId, variables: variables)
        dependencies.insert(baseKey)

        let page = graph.getRecord(baseKey)
        if baseIsCanonical {
            if page == nil { canonicalOK = false }
            let strictKey = Keys.buildConnectionKey(field: field, parentId: parentId, variables: variables)
            if graph.getRecord(strictKey) == nil { strictOK = false }
        } else {
            if page == nil { strictOK = false }
            let canonicalKey = Keys.buildConnectionCanonicalKey(field: field, parentId: parentId, variables: variables)
            if graph.getRecord(canonicalKey) == nil { canonicalOK = false }
        }

        guard let page else {
            out[outKey] = .object([CachebayConstants.connectionEdgesField: .array([]), CachebayConstants.connectionPageInfoField: .object([:])])
            return
        }

        var conn: [String: JSONValue] = [:]

        guard let selMap = field.selectionMap, !selMap.isEmpty else {
            out[outKey] = .object(conn)
            return
        }

        var edgeFingerprints: [UInt32] = []
        var pageInfoFingerprint: UInt32?

        for (responseKey, childField) in selMap {
            if responseKey == CachebayConstants.connectionPageInfoField {
                if let pageInfoLink = page[CachebayConstants.connectionPageInfoField], case .ref(let r) = pageInfoLink {
                    var fpPage: [String: JSONValue] = [:]
                    let (pv, piDict) = readPageInfo(pageInfoId: r, field: childField, fpOut: &fpPage)
                    conn[CachebayConstants.connectionPageInfoField] = .object(piDict)
                    if fingerprint { fpOut[CachebayConstants.connectionPageInfoField] = .object(fpPage) }
                    pageInfoFingerprint = pv
                } else {
                    conn[CachebayConstants.connectionPageInfoField] = .object([:])
                    strictOK = false; canonicalOK = false
                }
                continue
            }
            if responseKey == CachebayConstants.connectionEdgesField {
                let refs = page[CachebayConstants.connectionEdgesField]?.refList ?? []
                var edges: [JSONValue] = []
                var fpEdges: [JSONValue] = []
                edges.reserveCapacity(refs.count)
                fpEdges.reserveCapacity(refs.count)
                for (i, r) in refs.enumerated() {
                    var edgeFp: [String: JSONValue] = [:]
                    let edgeOut = readEdge(edgeKey: r, field: childField, fpEdge: &edgeFp, path: "\(path).edges[\(i)]")
                    edges.append(.object(edgeOut))
                    fpEdges.append(.object(edgeFp))
                    if case .int(let v) = edgeFp[CachebayConstants.fingerprintKey] ?? .undefined {
                        edgeFingerprints.append(UInt32(truncatingIfNeeded: v))
                    }
                }
                conn[CachebayConstants.connectionEdgesField] = .array(edges)
                if fingerprint { fpOut[CachebayConstants.connectionEdgesField] = .array(fpEdges) }
                continue
            }

            // Non-edges / non-pageInfo connection-level fields.
            if childField.selectionSet == nil {
                readScalar(page, field: childField, parentId: baseKey, into: &conn, outKey: childField.responseKey, path: "\(path).\(childField.responseKey)")
                continue
            }

            // Match cachebay-web: a connection field nested inside the
            // connection-level selection (rare, but valid — e.g.
            // `posts { tagsConnection @connection { ... } }`) is read
            // via `readConnection` recursively, NOT via the generic
            // ref/refList path below. Without this branch, the nested
            // connection's canonical/strict key would never be reached
            // and watchers depending on it would never fanout.
            if childField.isConnection {
                var childFp: [String: JSONValue] = [:]
                readConnection(parentId: baseKey, field: childField, out: &conn, outKey: childField.responseKey, fpOut: &childFp, path: "\(path).\(childField.responseKey)")
                if fingerprint { fpOut[childField.responseKey] = .object(childFp) }
                continue
            }

            let link = page[Keys.buildFieldKey(field: childField, variables: variables)]
            switch link {
            case .some(.ref(let r)):
                var childOut: [String: JSONValue] = [:]
                var childFp: [String: JSONValue] = [:]
                readEntity(r, field: childField, into: &childOut, fingerprint: &childFp, path: "\(path).\(childField.responseKey)")
                conn[childField.responseKey] = .object(childOut)
                if fingerprint { fpOut[childField.responseKey] = .object(childFp) }
            case .some(.refList(let refs)):
                var items: [JSONValue] = []
                var fpItems: [JSONValue] = []
                for (j, r) in refs.enumerated() {
                    var childOut: [String: JSONValue] = [:]
                    var childFp: [String: JSONValue] = [:]
                    readEntity(r, field: childField, into: &childOut, fingerprint: &childFp, path: "\(path).\(childField.responseKey)[\(j)]")
                    items.append(.object(childOut))
                    fpItems.append(.object(childFp))
                }
                conn[childField.responseKey] = .array(items)
                if fingerprint { fpOut[childField.responseKey] = .array(fpItems) }
            case .some(.null):
                conn[childField.responseKey] = .null
            default:
                conn[childField.responseKey] = .undefined
                strictOK = false; canonicalOK = false
            }
        }

        out[outKey] = .object(conn)
        let pageVersion = graph.version(baseKey)
        var children: [UInt32] = []
        if let pv = pageInfoFingerprint { children.append(pv) }
        if !edgeFingerprints.isEmpty { children.append(fingerprintNodes(0, edgeFingerprints)) }
        let connFp = children.isEmpty ? pageVersion : fingerprintNodes(pageVersion, children)
        if fingerprint { fpOut[CachebayConstants.fingerprintKey] = .int(Int64(connFp)) }
    }

    mutating func readPageInfo(pageInfoId: CacheKey, field: PlanField, fpOut: inout [String: JSONValue]) -> (UInt32, [String: JSONValue]) {
        dependencies.insert(pageInfoId)
        let rec = graph.getRecord(pageInfoId) ?? [:]
        var out: [String: JSONValue] = [:]
        if let children = field.selectionSet {
            for f in children {
                if f.selectionSet != nil { continue }
                readScalar(rec, field: f, parentId: pageInfoId, into: &out, outKey: f.responseKey, path: pageInfoId)
            }
        }
        let v = graph.version(pageInfoId)
        if fingerprint { fpOut[CachebayConstants.fingerprintKey] = .int(Int64(v)) }
        return (v, out)
    }

    mutating func readEdge(edgeKey: CacheKey, field: PlanField, fpEdge: inout [String: JSONValue], path: String) -> [String: JSONValue] {
        let rec = graph.getRecord(edgeKey) ?? [:]
        var edge: [String: JSONValue] = [:]
        if let tn = rec[CachebayConstants.typenameField] { edge[CachebayConstants.typenameField] = tn }

        guard let children = field.selectionSet else { return edge }
        var nodeFp: UInt32?
        for f in children {
            let outKey = f.responseKey
            if outKey == CachebayConstants.connectionNodeField {
                switch rec[CachebayConstants.connectionNodeField] {
                case .some(.ref(let r)):
                    var nodeOut: [String: JSONValue] = [:]
                    var nfp: [String: JSONValue] = [:]
                    readEntity(r, field: f, into: &nodeOut, fingerprint: &nfp, path: "\(path).node")
                    edge[CachebayConstants.connectionNodeField] = .object(nodeOut)
                    if fingerprint { fpEdge[CachebayConstants.connectionNodeField] = .object(nfp) }
                    if case .int(let v) = nfp[CachebayConstants.fingerprintKey] ?? .undefined {
                        nodeFp = UInt32(truncatingIfNeeded: v)
                    }
                case .some(.null):
                    edge[CachebayConstants.connectionNodeField] = .null
                default:
                    edge[CachebayConstants.connectionNodeField] = .undefined
                    strictOK = false; canonicalOK = false
                }
            } else if f.selectionSet == nil {
                readScalar(rec, field: f, parentId: edgeKey, into: &edge, outKey: outKey, path: "\(path).\(outKey)")
            }
        }

        let v = graph.version(edgeKey)
        let final = nodeFp.map { fingerprintNodes(v, [$0]) } ?? v
        if fingerprint { fpEdge[CachebayConstants.fingerprintKey] = .int(Int64(final)) }
        return edge
    }

    mutating func readScalar(_ record: [String: JSONValue], field: PlanField, parentId: CacheKey, into out: inout [String: JSONValue], outKey: String, path: String) {
        if field.fieldName == CachebayConstants.typenameField {
            out[outKey] = record[CachebayConstants.typenameField] ?? .undefined
            return
        }
        let storeKey = Keys.buildFieldKey(field: field, variables: variables)
        if let v = record[storeKey] {
            out[outKey] = v
        } else {
            // Scalar miss is a SOFT miss — write `.undefined` and emit a
            // diagnostic, but do NOT fail `canonicalOK`/`strictOK`. This
            // mirrors `cachebay-web`'s `readScalar` semantics: a single
            // missing scalar (e.g. an optimistic edge that has no
            // `cursor` because the caller didn't supply edge meta) must
            // not silence the entire watcher. Hard misses are entity
            // records and ref-link absences only — those have their
            // own `canonicalOK = false` paths above.
            out[outKey] = .undefined
            // Only warn when the parent record exists — a wholly-absent
            // record is a cold-cache read, not an actionable bug. A
            // present record missing a single scalar means a writer
            // (mutation, fragment, optimistic patch) populated the
            // record without the field this query selects.
            if !record.isEmpty {
                // Soft scalar miss — does NOT flip canonicalOK/strictOK.
                // Common during optimistic transactions (e.g. server-
                // assigned `cursor` field on a freshly added edge) and
                // recoverable on the next normalize. Logged at debug
                // level so it doesn't surface as an error in Console
                // for normal operation. Use `OS_ACTIVITY_MODE=enable`
                // or a `.debug` filter to see them while debugging.
                logger?.debug("[Cachebay] materialize soft miss: record \(parentId, privacy: .public) has no scalar '\(storeKey, privacy: .public)' (no OK flip; field returned undefined)")
            }
        }
    }

    private func selectionApplies(_ field: PlanField, runtimeType: String?) -> Bool {
        guard let typeCondition = field.typeCondition else { return true }
        guard let runtimeType else { return true }
        if typeCondition == runtimeType { return true }
        return graph.getImplementers(typeCondition).contains(runtimeType)
    }
}
