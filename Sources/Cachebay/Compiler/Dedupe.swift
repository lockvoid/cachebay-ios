import Foundation
import CachebayGraphQL

/// Compile-time de-duplication of selection sets.
/// - Fields: merge sub-selections (union) when (responseKey + argSig + dirSig) match.
/// - Inline fragments: merge by (typeCondition + dirSig).
/// - Fragment spreads: drop exact duplicates by (name + dirSig).
enum Dedupe {
    static func dedupeDocument(_ document: Document, fragments: [String: FragmentDefinition]) -> Document {
        var newDefs: [Definition] = []
        var seen: Set<String> = []

        for def in document.definitions {
            switch def {
            case .operation(let op):
                let deduped = dedupeSelections(op.selectionSet, parentType: rootTypename(for: op.operation))
                newDefs.append(.operation(OperationDefinition(
                    operation: op.operation,
                    name: op.name,
                    variableDefinitions: op.variableDefinitions,
                    directives: op.directives,
                    selectionSet: deduped,
                    location: op.location
                )))
            case .fragment(let fr):
                if seen.contains(fr.name) { continue }
                seen.insert(fr.name)
                let deduped = dedupeSelections(fr.selectionSet, parentType: fr.typeCondition)
                newDefs.append(.fragment(FragmentDefinition(
                    name: fr.name,
                    typeCondition: fr.typeCondition,
                    directives: fr.directives,
                    selectionSet: deduped,
                    location: fr.location
                )))
            case .schema:
                newDefs.append(def)
            }
        }
        return Document(definitions: newDefs)
    }

    private static func dedupeSelections(_ selections: [Selection], parentType: String) -> [Selection] {
        var fields: [(key: String, value: Field)] = []
        var fieldIndex: [String: Int] = [:]
        var inlines: [(key: String, value: InlineFragment)] = []
        var inlineIndex: [String: Int] = [:]
        var spreads: [(key: String, value: FragmentSpread)] = []
        var spreadIndex: [String: Int] = [:]
        var hasTypename = false

        for sel in selections {
            switch sel {
            case .field(let f):
                if f.name == CachebayConstants.typenameField {
                    if hasTypename { continue }
                    hasTypename = true
                    fields.append((key: "__typename", value: f))
                    continue
                }
                let key = fieldKey(f)
                if let existing = fieldIndex[key] {
                    let prev = fields[existing].value
                    let a = prev.selectionSet
                    let b = f.selectionSet
                    let merged: [Selection]
                    if !a.isEmpty && !b.isEmpty {
                        merged = dedupeSelections(a + b, parentType: parentType)
                    } else if !a.isEmpty {
                        merged = a
                    } else if !b.isEmpty {
                        merged = dedupeSelections(b, parentType: parentType)
                    } else {
                        merged = []
                    }
                    fields[existing] = (
                        key: key,
                        value: Field(
                            alias: prev.alias, name: prev.name, arguments: prev.arguments,
                            directives: prev.directives, selectionSet: merged, location: prev.location
                        )
                    )
                } else {
                    fieldIndex[key] = fields.count
                    fields.append((key: key, value: f))
                }
            case .inlineFragment(let ifr):
                let key = inlineKey(ifr, parent: parentType)
                if let existing = inlineIndex[key] {
                    let prev = inlines[existing].value
                    let a = prev.selectionSet
                    let b = ifr.selectionSet
                    let merged = !b.isEmpty ? dedupeSelections(a + b, parentType: ifr.typeCondition ?? parentType) : a
                    inlines[existing] = (
                        key: key,
                        value: InlineFragment(
                            typeCondition: prev.typeCondition, directives: prev.directives,
                            selectionSet: merged, location: prev.location
                        )
                    )
                } else {
                    inlineIndex[key] = inlines.count
                    inlines.append((key: key, value: ifr))
                }
            case .fragmentSpread(let sp):
                let key = spreadKey(sp)
                if spreadIndex[key] == nil {
                    spreadIndex[key] = spreads.count
                    spreads.append((key: key, value: sp))
                }
            }
        }

        // Dedupe inner selections for each field that has > 1 child
        for i in 0..<fields.count {
            let f = fields[i].value
            if f.selectionSet.count > 1 {
                let merged = dedupeSelections(f.selectionSet, parentType: parentType)
                fields[i] = (
                    key: fields[i].key,
                    value: Field(
                        alias: f.alias, name: f.name, arguments: f.arguments,
                        directives: f.directives, selectionSet: merged, location: f.location
                    )
                )
            }
        }

        // Build ordered output: fields first, then spreads, then inline fragments.
        var out: [Selection] = []
        out.reserveCapacity(fields.count + spreads.count + inlines.count)
        for (_, f) in fields { out.append(.field(f)) }
        for (_, sp) in spreads { out.append(.fragmentSpread(sp)) }
        for (_, ifr) in inlines { out.append(.inlineFragment(ifr)) }
        return out
    }

    // MARK: - Key builders

    private static func fieldKey(_ f: Field) -> String {
        let arg = argSig(f.arguments)
        let dir = directiveSig(f.directives)
        return "\(f.alias ?? f.name)|\(f.name)(\(arg))|\(dir)"
    }

    private static func inlineKey(_ ifr: InlineFragment, parent: String) -> String {
        let dir = directiveSig(ifr.directives)
        return "\(ifr.typeCondition ?? parent)|\(dir)"
    }

    private static func spreadKey(_ sp: FragmentSpread) -> String {
        let dir = directiveSig(sp.directives)
        return "\(sp.name)|\(dir)"
    }

    private static func argSig(_ args: [Argument]) -> String {
        if args.isEmpty { return "" }
        if args.count == 1 {
            return "\(args[0].name):\(valueSig(args[0].value))"
        }
        let sorted = args.sorted { $0.name < $1.name }
        return sorted.map { "\($0.name):\(valueSig($0.value))" }.joined(separator: ",")
    }

    private static func directiveSig(_ dirs: [Directive]) -> String {
        if dirs.isEmpty { return "" }
        if dirs.count == 1 {
            let a = argSig(dirs[0].arguments)
            return a.isEmpty ? "@\(dirs[0].name)" : "@\(dirs[0].name)(\(a))"
        }
        let sorted = dirs.sorted { $0.name < $1.name }
        return sorted.map {
            let a = argSig($0.arguments)
            return a.isEmpty ? "@\($0.name)" : "@\($0.name)(\(a))"
        }.joined(separator: ";")
    }

    private static func valueSig(_ v: Value) -> String {
        switch v {
        case .variable(let n): return "$\(n)"
        case .int(let i): return String(i)
        case .float(let d): return String(d)
        case .string(let s): return s
        case .boolean(let b): return String(b)
        case .null: return "null"
        case .enum(let e): return e
        case .list(let xs): return "[\(xs.map(valueSig).joined(separator: ","))]"
        case .object(let fields):
            let sorted = fields.sorted { $0.name < $1.name }
            return "{\(sorted.map { "\($0.name):\(valueSig($0.value))" }.joined(separator: ","))}"
        }
    }

    private static func rootTypename(for op: CachebayGraphQL.OperationKind) -> String {
        switch op {
        case .query: return "Query"
        case .mutation: return "Mutation"
        case .subscription: return "Subscription"
        }
    }
}
