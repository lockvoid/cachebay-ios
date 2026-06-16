import Foundation
import CachebayGraphQL

public enum Compiler {
    /// Compile a GraphQL document source into a `CachePlan`. If the document
    /// contains an operation, it is selected. Otherwise a fragment is selected
    /// (if there's exactly one, or `fragmentName` is provided).
    public static func compilePlan(source: String, fragmentName: String? = nil) throws -> CachePlan {
        let doc = try Parser.parse(source)
        return try compilePlan(document: doc, fragmentName: fragmentName)
    }

    /// Compile a pre-parsed document to a `CachePlan`.
    public static func compilePlan(document: Document, fragmentName: String? = nil) throws -> CachePlan {
        let fragsByName = document.fragmentsByName
        let deduped = Dedupe.dedupeDocument(document, fragments: fragsByName)
        let dedupedFragsByName = deduped.fragmentsByName

        if let op = deduped.operations.first {
            return try compileOperation(op, fragments: dedupedFragsByName, document: deduped)
        }
        let fragments = deduped.fragments
        if let frag = selectFragment(fragments, requested: fragmentName) {
            return try compileFragment(frag, fragments: dedupedFragsByName, document: deduped)
        }
        throw CachebayError.invalidPlan("No operation or fragment found in document")
    }

    // MARK: - Operation

    private static func compileOperation(
        _ op: OperationDefinition,
        fragments: [String: FragmentDefinition],
        document: Document
    ) throws -> CachePlan {
        let rootTypename = rootTypenameFor(op.operation)

        // Inject __typename into nested selections (not at the root).
        let selectionWithTypename = Typename.injectNested(op.selectionSet)
        let root = Lowering.lower(selections: selectionWithTypename, parentTypename: rootTypename, fragments: fragments)
        var rootMap: [String: PlanField] = [:]
        for f in root { rootMap[f.responseKey] = f }

        // Rebuild doc with __typename injected into fragments too, then strip @connection, then print.
        let rebuilt = Document(
            definitions: document.definitions.map { def -> Definition in
                switch def {
                case .operation(let o) where o == op:
                    return .operation(
                        OperationDefinition(
                            operation: o.operation, name: o.name,
                            variableDefinitions: o.variableDefinitions, directives: o.directives,
                            selectionSet: selectionWithTypename, location: o.location
                        ))
                case .fragment(let fr):
                    return .fragment(
                        FragmentDefinition(
                            name: fr.name, typeCondition: fr.typeCondition,
                            directives: fr.directives,
                            selectionSet: Typename.injectRecursive(fr.selectionSet),
                            location: fr.location
                        ))
                default: return def
                }
            })

        let networkQuery = buildNetworkQuery(from: rebuilt)

        let (strictMask, canonicalMask, windowArgs) = collectMasks(
            selectionSet: op.selectionSet, fragments: fragments, root: root
        )

        let fingerprint = Fingerprint.rootFingerprint(root, operation: op.operation.rawValue, rootTypename: rootTypename)
        let id = fnv1a32(fingerprint)

        let kind: OperationKind = {
            switch op.operation {
            case .query: return .query
            case .mutation: return .mutation
            case .subscription: return .subscription
            }
        }()

        return CachePlan(
            operation: kind,
            rootTypename: rootTypename,
            root: root,
            rootSelectionMap: rootMap,
            networkQuery: networkQuery,
            // Runtime-compiled plans skip APQ — send the full query. (Hashing
            // here would need a Swift SHA-256; codegen is the APQ path.)
            persistedHash: nil,
            id: id,
            varMask: VarMask(strict: strictMask, canonical: canonicalMask),
            windowArgs: windowArgs,
            selectionFingerprint: fingerprint
        )
    }

    // MARK: - Fragment

    private static func compileFragment(
        _ frag: FragmentDefinition,
        fragments: [String: FragmentDefinition],
        document: Document
    ) throws -> CachePlan {
        let parentTypename = frag.typeCondition
        let fragSelectionWithTypename = Typename.injectRecursive(frag.selectionSet)
        let root = Lowering.lower(selections: fragSelectionWithTypename, parentTypename: parentTypename, fragments: fragments)
        var rootMap: [String: PlanField] = [:]
        for f in root { rootMap[f.responseKey] = f }

        let rebuilt = Document(
            definitions: document.definitions.map { def -> Definition in
                if case .fragment = def {
                    // re-run injection over each fragment for consistency
                    if case .fragment(let fr) = def {
                        return .fragment(
                            FragmentDefinition(
                                name: fr.name, typeCondition: fr.typeCondition,
                                directives: fr.directives,
                                selectionSet: Typename.injectRecursive(fr.selectionSet),
                                location: fr.location
                            ))
                    }
                }
                return def
            })
        let networkQuery = buildNetworkQuery(from: rebuilt)

        let (strictMask, canonicalMask, windowArgs) = collectMasks(
            selectionSet: frag.selectionSet, fragments: fragments, root: root
        )

        let fingerprint = Fingerprint.rootFingerprint(root, operation: "fragment", rootTypename: parentTypename)
        let id = fnv1a32(fingerprint)

        return CachePlan(
            operation: .fragment,
            rootTypename: parentTypename,
            root: root,
            rootSelectionMap: rootMap,
            networkQuery: networkQuery,
            persistedHash: nil,
            id: id,
            varMask: VarMask(strict: strictMask, canonical: canonicalMask),
            windowArgs: windowArgs,
            selectionFingerprint: fingerprint
        )
    }

    // MARK: - Helpers

    private static func selectFragment(_ fragments: [FragmentDefinition], requested: String?) -> FragmentDefinition? {
        if fragments.isEmpty { return nil }
        if let name = requested {
            return fragments.first { $0.name == name }
        }
        if fragments.count == 1 { return fragments[0] }
        return nil
    }

    private static func rootTypenameFor(_ op: CachebayGraphQL.OperationKind) -> String {
        switch op {
        case .query: return "Query"
        case .mutation: return "Mutation"
        case .subscription: return "Subscription"
        }
    }

    /// Collect strict variable mask (all variable names referenced anywhere)
    /// and canonical mask (strict minus window args). Also returns windowArgs.
    private static func collectMasks(
        selectionSet: [Selection],
        fragments: [String: FragmentDefinition],
        root: [PlanField]
    ) -> (strict: [String], canonical: [String], windowArgs: Set<String>) {
        var strict: Set<String> = []
        var visited: Set<String> = []
        collectVarsFromSelectionSet(selectionSet, fragments: fragments, visited: &visited, into: &strict)

        var windowArgs: Set<String> = []
        walkPlanForWindowArgs(root, into: &windowArgs)

        var canonical: Set<String> = []
        for v in strict where !windowArgs.contains(v) {
            canonical.insert(v)
        }
        return (Array(strict), Array(canonical), windowArgs)
    }

    private static func walkPlanForWindowArgs(_ fields: [PlanField], into set: inout Set<String>) {
        for field in fields {
            if field.isConnection, let args = field.pageArgs {
                for a in args { set.insert(a) }
            }
            if let children = field.selectionSet {
                walkPlanForWindowArgs(children, into: &set)
            }
        }
    }

    private static func collectVarsFromSelectionSet(
        _ selections: [Selection],
        fragments: [String: FragmentDefinition],
        visited: inout Set<String>,
        into set: inout Set<String>
    ) {
        for sel in selections {
            switch sel {
            case .field(let f):
                for arg in f.arguments { collectVars(arg.value, into: &set) }
                for dir in f.directives {
                    for arg in dir.arguments { collectVars(arg.value, into: &set) }
                }
                if !f.selectionSet.isEmpty {
                    collectVarsFromSelectionSet(f.selectionSet, fragments: fragments, visited: &visited, into: &set)
                }
            case .inlineFragment(let ifr):
                collectVarsFromSelectionSet(ifr.selectionSet, fragments: fragments, visited: &visited, into: &set)
            case .fragmentSpread(let sp):
                if visited.contains(sp.name) { continue }
                visited.insert(sp.name)
                if let frag = fragments[sp.name] {
                    collectVarsFromSelectionSet(frag.selectionSet, fragments: fragments, visited: &visited, into: &set)
                }
            }
        }
    }

    private static func collectVars(_ v: Value, into set: inout Set<String>) {
        switch v {
        case .variable(let name): set.insert(name)
        case .list(let xs): for x in xs { collectVars(x, into: &set) }
        case .object(let fields): for f in fields { collectVars(f.value, into: &set) }
        default: break
        }
    }
}

/// Inject `__typename` into appropriate selection sets and strip `@connection`
/// directives for the network query string.
enum Typename {
    static func injectNested(_ selections: [Selection]) -> [Selection] {
        // Do NOT add __typename at this level; recurse into children.
        return selections.map { sel -> Selection in
            switch sel {
            case .field(let f) where !f.selectionSet.isEmpty:
                return .field(
                    Field(
                        alias: f.alias, name: f.name, arguments: f.arguments,
                        directives: f.directives,
                        selectionSet: injectRecursive(f.selectionSet),
                        location: f.location
                    ))
            case .inlineFragment(let ifr):
                return .inlineFragment(
                    InlineFragment(
                        typeCondition: ifr.typeCondition, directives: ifr.directives,
                        selectionSet: injectRecursive(ifr.selectionSet),
                        location: ifr.location
                    ))
            default: return sel
            }
        }
    }

    static func injectRecursive(_ selections: [Selection]) -> [Selection] {
        var hasTypename = false
        for sel in selections {
            if case .field(let f) = sel, f.name == CachebayConstants.typenameField {
                hasTypename = true; break
            }
        }
        var out: [Selection] = []
        out.reserveCapacity(selections.count + 1)
        for sel in selections {
            switch sel {
            case .field(let f):
                if f.selectionSet.isEmpty {
                    out.append(.field(f))
                } else {
                    out.append(
                        .field(
                            Field(
                                alias: f.alias, name: f.name, arguments: f.arguments,
                                directives: f.directives,
                                selectionSet: injectRecursive(f.selectionSet),
                                location: f.location
                            )))
                }
            case .inlineFragment(let ifr):
                out.append(
                    .inlineFragment(
                        InlineFragment(
                            typeCondition: ifr.typeCondition, directives: ifr.directives,
                            selectionSet: injectRecursive(ifr.selectionSet),
                            location: ifr.location
                        )))
            default: out.append(sel)
            }
        }
        if !hasTypename {
            out.append(.field(Field(name: CachebayConstants.typenameField)))
        }
        return out
    }
}

/// Strip `@connection` directives everywhere; produce a printed query string.
func buildNetworkQuery(from document: Document) -> String {
    let stripper = Visitor(
        enterField: { f in
            if f.directives.isEmpty { return .keep }
            let filtered = f.directives.filter { $0.name != CachebayConstants.connectionDirective }
            if filtered.count == f.directives.count { return .keep }
            return .replace(
                Field(
                    alias: f.alias, name: f.name, arguments: f.arguments,
                    directives: filtered, selectionSet: f.selectionSet, location: f.location
                ))
        }
    )
    let cleaned = stripper.visit(document)
    return Printer.print(cleaned)
}
