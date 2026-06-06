import Foundation
import CachebayGraphQL

/// Lowering: Document AST → PlanField tree. Mirrors
/// `src/compiler/lowering/flatten.ts` from cachebay-web.
enum Lowering {
    /// Lower a selection set into `[PlanField]`. `guardType` carries the active
    /// inline-fragment/fragment-spread type condition so produced fields inherit
    /// `typeCondition` for runtime type-guarding.
    static func lower(
        selections: [Selection],
        parentTypename: String,
        fragments: [String: FragmentDefinition],
        guardType: String? = nil
    ) -> [PlanField] {
        var out: [PlanField] = []
        for sel in selections {
            switch sel {
            case .field(let f):
                out.append(lowerField(f, parentTypename: parentTypename, fragments: fragments, guardType: guardType))
            case .inlineFragment(let inlineFragment):
                let nextParent = inlineFragment.typeCondition ?? parentTypename
                let nextGuard = inlineFragment.typeCondition ?? guardType
                let lowered = lower(selections: inlineFragment.selectionSet, parentTypename: nextParent, fragments: fragments, guardType: nextGuard)
                out.append(contentsOf: lowered)
            case .fragmentSpread(let spread):
                guard let frag = fragments[spread.name] else { continue }
                let nextParent = frag.typeCondition
                let nextGuard = frag.typeCondition
                let lowered = lower(selections: frag.selectionSet, parentTypename: nextParent, fragments: fragments, guardType: nextGuard)
                out.append(contentsOf: lowered)
            }
        }
        return out
    }

    private static func lowerField(
        _ node: Field,
        parentTypename: String,
        fragments: [String: FragmentDefinition],
        guardType: String?
    ) -> PlanField {
        let responseKey = node.alias ?? node.name
        let fieldName = node.name

        // Child selection set
        var childPlan: [PlanField]? = nil
        var childMap: [String: PlanField]? = nil
        if !node.selectionSet.isEmpty {
            let childParent = inferChildParent(selectionSet: node.selectionSet, defaultParent: parentTypename, fragments: fragments)
            let lowered = lower(selections: node.selectionSet, parentTypename: childParent, fragments: fragments, guardType: guardType)
            childPlan = lowered
            var m: [String: PlanField] = [:]
            for f in lowered { m[f.responseKey] = f }
            childMap = m
        }

        // Arguments
        let (buildArgs, expectedArgNames) = compileArgBuilder(node.arguments)
        let stringifyArgs = compileStringifyArgs(expectedArgNames: expectedArgNames, buildArgs: buildArgs)

        // @connection metadata
        var isConnection = false
        var connectionKey: String? = nil
        var connectionFilters: [String]? = nil
        var connectionMode: ConnectionMode? = nil
        var pageArgs: [String]? = nil

        if let dir = node.directives.first(where: { $0.name == CachebayConstants.connectionDirective }) {
            isConnection = true
            var parsedKey: String? = nil
            var parsedFilters: [String]? = nil
            var parsedMode: ConnectionMode? = nil
            for arg in dir.arguments {
                switch arg.name {
                case "key":
                    if case .string(let s) = arg.value, !s.isEmpty { parsedKey = s }
                case "filters":
                    if case .list(let items) = arg.value {
                        parsedFilters = items.compactMap {
                            if case .string(let s) = $0 { return s } else { return nil }
                        }.filter { !$0.isEmpty }
                    }
                case "mode":
                    if case .string(let s) = arg.value, let mode = ConnectionMode(rawValue: s) {
                        parsedMode = mode
                    }
                default: break
                }
            }
            connectionKey = parsedKey ?? fieldName
            connectionMode = parsedMode
            if let filters = parsedFilters, !filters.isEmpty {
                connectionFilters = filters
            } else {
                let inferred = node.arguments.map(\.name).filter { !CachebayConstants.paginationArgs.contains($0) }
                connectionFilters = inferred
            }
            pageArgs = node.arguments.map(\.name).filter { CachebayConstants.paginationArgs.contains($0) }
        }

        // Parse @skip / @include directives. Spec-mandated; honoured at
        // runtime in materialize + normalize via `shouldInclude(variables:)`.
        var skipIf: DirectiveCondition? = nil
        var includeIf: DirectiveCondition? = nil
        for dir in node.directives {
            switch dir.name {
            case "skip":
                if let arg = dir.arguments.first(where: { $0.name == "if" }) {
                    skipIf = directiveCondition(from: arg.value)
                }
            case "include":
                if let arg = dir.arguments.first(where: { $0.name == "if" }) {
                    includeIf = directiveCondition(from: arg.value)
                }
            default:
                break
            }
        }

        // Build partial PlanField (with placeholder selId so we can compute fingerprint)
        let selId = Fingerprint.fieldSelId(
            responseKey: responseKey,
            fieldName: fieldName,
            typeCondition: guardType,
            isConnection: isConnection,
            argNames: expectedArgNames,
            children: childPlan ?? []
        )

        return PlanField(
            responseKey: responseKey,
            fieldName: fieldName,
            selectionSet: childPlan,
            selectionMap: childMap,
            typeCondition: guardType,
            expectedArgNames: expectedArgNames,
            buildArgs: buildArgs,
            stringifyArgs: stringifyArgs,
            isConnection: isConnection,
            connectionKey: connectionKey,
            connectionFilters: connectionFilters,
            connectionMode: connectionMode,
            pageArgs: pageArgs,
            // Runtime-compiled plans have no schema, so no edge type here; codegen
            // plans carry it. Optimistic inserts on a runtime-compiled connection
            // fall back to sibling-copy then guess.
            connectionEdgeTypename: nil,
            skipIf: skipIf,
            includeIf: includeIf,
            selId: selId
        )
    }

    /// Lift a directive `if:` argument into a `DirectiveCondition`.
    /// Returns `nil` for shapes the spec doesn't define (e.g. `if: $foo.bar`,
    /// `if: 1`) — those would have failed validation server-side anyway.
    private static func directiveCondition(from value: Value) -> DirectiveCondition? {
        switch value {
        case .boolean(let b): return .constant(b)
        case .variable(let name): return .variable(name)
        default: return nil
        }
    }

    private static func inferChildParent(
        selectionSet: [Selection],
        defaultParent: String,
        fragments: [String: FragmentDefinition]
    ) -> String {
        var typeNames: Set<String> = []
        for sel in selectionSet {
            switch sel {
            case .inlineFragment(let inlineFragment):
                if let tc = inlineFragment.typeCondition { typeNames.insert(tc) }
            case .fragmentSpread(let sp):
                if let frag = fragments[sp.name] { typeNames.insert(frag.typeCondition) }
            case .field: break
            }
        }
        if typeNames.count == 1, let only = typeNames.first { return only }
        return defaultParent
    }
}

// MARK: - Args

private func compileArgBuilder(_ args: [Argument]) -> (@Sendable ([String: JSONValue]) -> [String: JSONValue], [String]) {
    if args.isEmpty {
        return ({ _ in [:] }, [])
    }
    struct Entry: Sendable { let name: String; let node: Value }
    let entries: [Entry] = args.map { Entry(name: $0.name, node: $0.value) }
    let expected: [String] = entries.map(\.name)

    let build: @Sendable ([String: JSONValue]) -> [String: JSONValue] = { vars in
        var out: [String: JSONValue] = [:]
        out.reserveCapacity(entries.count)
        for e in entries {
            let resolved = resolveValue(e.node, variables: vars)
            switch resolved {
            case .undefined: continue
            default: out[e.name] = resolved
            }
        }
        return out
    }
    return (build, expected)
}

private func resolveValue(_ node: Value, variables: [String: JSONValue]) -> JSONValue {
    switch node {
    case .null: return .null
    case .int(let i): return .int(i)
    case .float(let d): return .double(d)
    case .string(let s): return .string(s)
    case .boolean(let b): return .bool(b)
    case .enum(let e): return .string(e)
    case .list(let items):
        return .array(items.map { resolveValue($0, variables: variables) })
    case .object(let fields):
        var obj: [String: JSONValue] = [:]
        for field in fields {
            let v = resolveValue(field.value, variables: variables)
            if case .undefined = v { continue }
            obj[field.name] = v
        }
        return .object(obj)
    case .variable(let name):
        return variables[name] ?? .undefined
    }
}

private func compileStringifyArgs(expectedArgNames: [String], buildArgs: @escaping @Sendable ([String: JSONValue]) -> [String: JSONValue]) -> @Sendable ([String: JSONValue]) -> String {
    if expectedArgNames.isEmpty {
        return { _ in "" }
    }
    let encodedKeys: [String] = expectedArgNames.map { "\"\($0)\":" }
    return { vars in
        let args = buildArgs(vars)
        var parts: [String] = []
        parts.reserveCapacity(expectedArgNames.count)
        for i in 0..<expectedArgNames.count {
            if let val = args[expectedArgNames[i]] {
                parts.append(encodedKeys[i] + stableStringify(val))
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}
