import Foundation

/// Prints a GraphQL Document back to its string form. Minimal but round-trippable
/// for Lexer/Parser input. Intended for building network-safe queries after
/// directive stripping / __typename injection.
public enum Printer {
    public static func print(_ document: Document) -> String {
        var out: [String] = []
        for def in document.definitions {
            switch def {
            case .operation(let op): out.append(printOperation(op))
            case .fragment(let fr): out.append(printFragment(fr))
            case .schema: break
            }
        }
        return out.joined(separator: "\n\n")
    }

    public static func print(_ operation: OperationDefinition) -> String { printOperation(operation) }
    public static func print(_ fragment: FragmentDefinition) -> String { printFragment(fragment) }
    public static func print(_ value: Value) -> String { printValue(value) }

    // MARK: -

    private static func printOperation(_ op: OperationDefinition) -> String {
        var parts: [String] = []
        let header: String
        if op.operation == .query && op.name == nil && op.variableDefinitions.isEmpty && op.directives.isEmpty {
            header = ""
        } else {
            var h = op.operation.rawValue
            if let n = op.name { h += " \(n)" }
            if !op.variableDefinitions.isEmpty {
                h += "(" + op.variableDefinitions.map(printVariableDef).joined(separator: ", ") + ")"
            }
            if !op.directives.isEmpty {
                h += " " + op.directives.map(printDirective).joined(separator: " ")
            }
            header = h
        }
        if !header.isEmpty { parts.append(header) }
        parts.append(printSelectionSet(op.selectionSet, indent: 0))
        return parts.joined(separator: " ")
    }

    private static func printFragment(_ f: FragmentDefinition) -> String {
        var h = "fragment \(f.name) on \(f.typeCondition)"
        if !f.directives.isEmpty {
            h += " " + f.directives.map(printDirective).joined(separator: " ")
        }
        return h + " " + printSelectionSet(f.selectionSet, indent: 0)
    }

    private static func printVariableDef(_ v: VariableDefinition) -> String {
        var s = "$\(v.name): \(printType(v.type))"
        if let def = v.defaultValue { s += " = \(printValue(def))" }
        if !v.directives.isEmpty { s += " " + v.directives.map(printDirective).joined(separator: " ") }
        return s
    }

    public static func printType(_ t: TypeReference) -> String {
        switch t {
        case .named(let n): return n
        case .list(let inner): return "[\(printType(inner))]"
        case .nonNull(let inner): return printType(inner) + "!"
        }
    }

    public static func printDirective(_ d: Directive) -> String {
        if d.arguments.isEmpty { return "@\(d.name)" }
        return "@\(d.name)(" + d.arguments.map { "\($0.name): \(printValue($0.value))" }.joined(separator: ", ") + ")"
    }

    public static func printValue(_ v: Value) -> String {
        switch v {
        case .variable(let n): return "$\(n)"
        case .int(let x): return String(x)
        case .float(let x): return String(x)
        case .string(let s): return "\"" + escape(s) + "\""
        case .boolean(let b): return b ? "true" : "false"
        case .null: return "null"
        case .enum(let e): return e
        case .list(let xs): return "[" + xs.map(printValue).joined(separator: ", ") + "]"
        case .object(let fields):
            return "{" + fields.map { "\($0.name): \(printValue($0.value))" }.joined(separator: ", ") + "}"
        }
    }

    private static func printSelectionSet(_ sels: [Selection], indent: Int) -> String {
        if sels.isEmpty { return "{}" }
        let pad = String(repeating: "  ", count: indent + 1)
        let body = sels.map { pad + printSelection($0, indent: indent + 1) }.joined(separator: "\n")
        let closingPad = String(repeating: "  ", count: indent)
        return "{\n" + body + "\n" + closingPad + "}"
    }

    private static func printSelection(_ sel: Selection, indent: Int) -> String {
        switch sel {
        case .field(let f):
            var s = ""
            if let alias = f.alias { s += "\(alias): " }
            s += f.name
            if !f.arguments.isEmpty {
                s += "(" + f.arguments.map { "\($0.name): \(printValue($0.value))" }.joined(separator: ", ") + ")"
            }
            if !f.directives.isEmpty {
                s += " " + f.directives.map(printDirective).joined(separator: " ")
            }
            if !f.selectionSet.isEmpty {
                s += " " + printSelectionSet(f.selectionSet, indent: indent)
            }
            return s
        case .inlineFragment(let ifr):
            var s = "..."
            if let tc = ifr.typeCondition { s += " on \(tc)" }
            if !ifr.directives.isEmpty { s += " " + ifr.directives.map(printDirective).joined(separator: " ") }
            s += " " + printSelectionSet(ifr.selectionSet, indent: indent)
            return s
        case .fragmentSpread(let sp):
            var s = "... \(sp.name)"
            if !sp.directives.isEmpty { s += " " + sp.directives.map(printDirective).joined(separator: " ") }
            return s
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}
