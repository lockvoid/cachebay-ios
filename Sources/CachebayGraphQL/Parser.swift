import Foundation

/// Recursive-descent parser for GraphQL executable documents and SDL.
public struct Parser {
    private var lexer: Lexer
    private var current: Token

    public init(source: String) throws {
        var l = Lexer(source: source)
        let tok = try l.next()
        self.lexer = l
        self.current = tok
    }

    public static func parse(_ source: String) throws -> Document {
        var p = try Parser(source: source)
        return try p.parseDocument()
    }

    public static func parseType(_ source: String) throws -> TypeReference {
        var p = try Parser(source: source)
        return try p.parseTypeReference()
    }

    public static func parseValue(_ source: String) throws -> Value {
        var p = try Parser(source: source)
        return try p.parseValueLiteral(isConst: false)
    }

    // MARK: - Cursor

    @discardableResult
    private mutating func advance() throws -> Token {
        let prev = current
        current = try lexer.next()
        return prev
    }

    private mutating func expect(_ kind: TokenKind) throws -> Token {
        if current.kind == kind { return try advance() }
        throw syntax("Expected \(kind), got \(current.kind) '\(current.value)'")
    }

    private mutating func expectName(_ name: String) throws {
        if current.kind == .name, current.value == name {
            _ = try advance()
            return
        }
        throw syntax("Expected '\(name)', got '\(current.value)'")
    }

    private mutating func peekName(_ name: String) -> Bool {
        return current.kind == .name && current.value == name
    }

    private func syntax(_ msg: String) -> SyntaxError {
        SyntaxError(message: msg, line: current.line, column: current.column)
    }

    // MARK: - Document

    public mutating func parseDocument() throws -> Document {
        var defs: [Definition] = []
        var typeDefs: [TypeDefinition] = []
        var schemaQueryType: String? = nil
        var schemaMutationType: String? = nil
        var schemaSubscriptionType: String? = nil
        var seenSchemaDef = false

        while current.kind != .eof {
            // Skip descriptions
            let desc = try readDescription()
            if current.kind == .brace(open: true) {
                // Shorthand query
                let sels = try parseSelectionSet()
                defs.append(.operation(OperationDefinition(operation: .query, selectionSet: sels)))
                continue
            }
            if current.kind == .name {
                switch current.value {
                case "query", "mutation", "subscription":
                    defs.append(.operation(try parseOperationDefinition()))
                case "fragment":
                    defs.append(.fragment(try parseFragmentDefinition()))
                case "schema":
                    let info = try parseSchemaDefinitionHeader()
                    schemaQueryType = info.query ?? schemaQueryType
                    schemaMutationType = info.mutation ?? schemaMutationType
                    schemaSubscriptionType = info.subscription ?? schemaSubscriptionType
                    seenSchemaDef = true
                case "type":
                    typeDefs.append(.object(try parseObjectTypeDefinition(description: desc)))
                case "interface":
                    typeDefs.append(.interface(try parseInterfaceTypeDefinition(description: desc)))
                case "union":
                    typeDefs.append(.union(try parseUnionTypeDefinition(description: desc)))
                case "enum":
                    typeDefs.append(.enum(try parseEnumTypeDefinition(description: desc)))
                case "scalar":
                    typeDefs.append(.scalar(try parseScalarTypeDefinition(description: desc)))
                case "input":
                    typeDefs.append(.inputObject(try parseInputObjectTypeDefinition(description: desc)))
                case "extend":
                    try skipExtension()
                case "directive":
                    try skipDirectiveDefinition()
                default:
                    throw syntax("Unexpected name '\(current.value)'")
                }
            } else {
                throw syntax("Unexpected token \(current.kind) '\(current.value)'")
            }
            _ = desc
        }

        if !typeDefs.isEmpty || seenSchemaDef {
            defs.append(.schema(SchemaDefinition(
                types: typeDefs,
                queryType: schemaQueryType,
                mutationType: schemaMutationType,
                subscriptionType: schemaSubscriptionType
            )))
        }

        return Document(definitions: defs)
    }

    private mutating func readDescription() throws -> String? {
        if current.kind == .string || current.kind == .blockString {
            let tok = try advance()
            return tok.value
        }
        return nil
    }

    private mutating func skipExtension() throws {
        // Best-effort: consume `extend` then skip one definition.
        _ = try advance() // extend
        if current.kind == .name {
            switch current.value {
            case "type": _ = try? parseObjectTypeDefinition(description: nil)
            case "interface": _ = try? parseInterfaceTypeDefinition(description: nil)
            case "union": _ = try? parseUnionTypeDefinition(description: nil)
            case "enum": _ = try? parseEnumTypeDefinition(description: nil)
            case "scalar": _ = try? parseScalarTypeDefinition(description: nil)
            case "input": _ = try? parseInputObjectTypeDefinition(description: nil)
            default: _ = try advance()
            }
        }
    }

    private mutating func skipDirectiveDefinition() throws {
        _ = try advance() // directive
        _ = try expect(.at)
        _ = try expect(.name)
        if current.kind == .paren(open: true) {
            _ = try parseInputValueDefinitions()
        }
        if peekName("repeatable") { _ = try advance() }
        try expectName("on")
        // Location list
        _ = try expect(.name)
        while current.kind == .pipe {
            _ = try advance()
            _ = try expect(.name)
        }
    }

    // MARK: - Operation / Fragment

    private mutating func parseOperationDefinition() throws -> OperationDefinition {
        let startTok = current
        guard let kind = OperationKind(rawValue: current.value) else {
            throw syntax("Expected operation kind")
        }
        _ = try advance()
        var name: String? = nil
        if current.kind == .name {
            name = current.value
            _ = try advance()
        }
        var varDefs: [VariableDefinition] = []
        if current.kind == .paren(open: true) {
            varDefs = try parseVariableDefinitions()
        }
        let dirs = try parseDirectives(isConst: false)
        let sels = try parseSelectionSet()
        return OperationDefinition(
            operation: kind,
            name: name,
            variableDefinitions: varDefs,
            directives: dirs,
            selectionSet: sels,
            location: startTok.location
        )
    }

    private mutating func parseFragmentDefinition() throws -> FragmentDefinition {
        let startTok = current
        _ = try advance() // 'fragment'
        let nameTok = try expect(.name)
        if nameTok.value == "on" { throw syntax("'on' is not a valid fragment name") }
        try expectName("on")
        let typeCondition = try expect(.name).value
        let dirs = try parseDirectives(isConst: false)
        let sels = try parseSelectionSet()
        return FragmentDefinition(name: nameTok.value, typeCondition: typeCondition, directives: dirs, selectionSet: sels, location: startTok.location)
    }

    // MARK: - Variable Definitions

    private mutating func parseVariableDefinitions() throws -> [VariableDefinition] {
        _ = try expect(.paren(open: true))
        var defs: [VariableDefinition] = []
        while current.kind != .paren(open: false) {
            _ = try expect(.dollar)
            let nameTok = try expect(.name)
            _ = try expect(.colon)
            let ty = try parseTypeReference()
            var defVal: Value? = nil
            if current.kind == .equals {
                _ = try advance()
                defVal = try parseValueLiteral(isConst: true)
            }
            let dirs = try parseDirectives(isConst: true)
            defs.append(VariableDefinition(name: nameTok.value, type: ty, defaultValue: defVal, directives: dirs, location: nameTok.location))
        }
        _ = try expect(.paren(open: false))
        return defs
    }

    // MARK: - Types

    public mutating func parseTypeReference() throws -> TypeReference {
        var ty: TypeReference
        if current.kind == .bracket(open: true) {
            _ = try advance()
            let inner = try parseTypeReference()
            _ = try expect(.bracket(open: false))
            ty = .list(inner)
        } else {
            let nameTok = try expect(.name)
            ty = .named(nameTok.value)
        }
        if current.kind == .bang {
            _ = try advance()
            ty = .nonNull(ty)
        }
        return ty
    }

    // MARK: - Directives / Arguments

    private mutating func parseDirectives(isConst: Bool) throws -> [Directive] {
        var dirs: [Directive] = []
        while current.kind == .at {
            _ = try advance()
            let nameTok = try expect(.name)
            var args: [Argument] = []
            if current.kind == .paren(open: true) {
                args = try parseArguments(isConst: isConst)
            }
            dirs.append(Directive(name: nameTok.value, arguments: args, location: nameTok.location))
        }
        return dirs
    }

    private mutating func parseArguments(isConst: Bool) throws -> [Argument] {
        _ = try expect(.paren(open: true))
        var args: [Argument] = []
        while current.kind != .paren(open: false) {
            let nameTok = try expect(.name)
            _ = try expect(.colon)
            let val = try parseValueLiteral(isConst: isConst)
            args.append(Argument(name: nameTok.value, value: val, location: nameTok.location))
        }
        _ = try expect(.paren(open: false))
        return args
    }

    // MARK: - Values

    public mutating func parseValueLiteral(isConst: Bool) throws -> Value {
        switch current.kind {
        case .bracket(open: true):
            _ = try advance()
            var items: [Value] = []
            while current.kind != .bracket(open: false) {
                items.append(try parseValueLiteral(isConst: isConst))
            }
            _ = try advance()
            return .list(items)
        case .brace(open: true):
            _ = try advance()
            var fields: [ObjectField] = []
            while current.kind != .brace(open: false) {
                let nameTok = try expect(.name)
                _ = try expect(.colon)
                let val = try parseValueLiteral(isConst: isConst)
                fields.append(ObjectField(name: nameTok.value, value: val))
            }
            _ = try advance()
            return .object(fields)
        case .int:
            let t = try advance()
            return .int(Int64(t.value) ?? 0)
        case .float:
            let t = try advance()
            return .float(Double(t.value) ?? 0)
        case .string, .blockString:
            let t = try advance()
            return .string(t.value)
        case .dollar:
            if isConst { throw syntax("Variables not allowed in const value") }
            _ = try advance()
            let nameTok = try expect(.name)
            return .variable(nameTok.value)
        case .name:
            let t = try advance()
            switch t.value {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            case "null": return .null
            default: return .enum(t.value)
            }
        default:
            throw syntax("Unexpected token in value: \(current.kind) '\(current.value)'")
        }
    }

    // MARK: - Selection Set

    public mutating func parseSelectionSet() throws -> [Selection] {
        _ = try expect(.brace(open: true))
        var sels: [Selection] = []
        while current.kind != .brace(open: false) {
            if current.kind == .spread {
                sels.append(try parseFragment())
            } else {
                sels.append(try parseFieldSelection())
            }
        }
        _ = try expect(.brace(open: false))
        return sels
    }

    private mutating func parseFieldSelection() throws -> Selection {
        let startTok = current
        let nameTok = try expect(.name)
        var alias: String? = nil
        var fieldName = nameTok.value
        if current.kind == .colon {
            _ = try advance()
            alias = fieldName
            fieldName = try expect(.name).value
        }
        var args: [Argument] = []
        if current.kind == .paren(open: true) {
            args = try parseArguments(isConst: false)
        }
        let dirs = try parseDirectives(isConst: false)
        var selSet: [Selection] = []
        if current.kind == .brace(open: true) {
            selSet = try parseSelectionSet()
        }
        return .field(Field(alias: alias, name: fieldName, arguments: args, directives: dirs, selectionSet: selSet, location: startTok.location))
    }

    private mutating func parseFragment() throws -> Selection {
        let startTok = current
        _ = try advance() // '...'
        // inline?
        if current.kind == .name && current.value == "on" {
            _ = try advance()
            let typeCond = try expect(.name).value
            let dirs = try parseDirectives(isConst: false)
            let sels = try parseSelectionSet()
            return .inlineFragment(InlineFragment(typeCondition: typeCond, directives: dirs, selectionSet: sels, location: startTok.location))
        }
        if current.kind == .brace(open: true) {
            // inline without type condition
            let dirs: [Directive] = []
            let sels = try parseSelectionSet()
            return .inlineFragment(InlineFragment(typeCondition: nil, directives: dirs, selectionSet: sels, location: startTok.location))
        }
        if current.kind == .name {
            let nameTok = try advance()
            let dirs = try parseDirectives(isConst: false)
            return .fragmentSpread(FragmentSpread(name: nameTok.value, directives: dirs, location: startTok.location))
        }
        if current.kind == .at {
            // inline with directives, no type cond
            let dirs = try parseDirectives(isConst: false)
            let sels = try parseSelectionSet()
            return .inlineFragment(InlineFragment(typeCondition: nil, directives: dirs, selectionSet: sels, location: startTok.location))
        }
        throw syntax("Expected fragment name, inline fragment, or directives")
    }

    // MARK: - SDL: schema / type / interface / union / enum / scalar / input

    struct SchemaHeaderInfo { var query: String?; var mutation: String?; var subscription: String? }

    private mutating func parseSchemaDefinitionHeader() throws -> SchemaHeaderInfo {
        _ = try advance() // 'schema'
        _ = try parseDirectives(isConst: true)
        var info = SchemaHeaderInfo()
        if current.kind == .brace(open: true) {
            _ = try advance()
            while current.kind != .brace(open: false) {
                let roleTok = try expect(.name)
                _ = try expect(.colon)
                let typeTok = try expect(.name)
                switch roleTok.value {
                case "query": info.query = typeTok.value
                case "mutation": info.mutation = typeTok.value
                case "subscription": info.subscription = typeTok.value
                default: break
                }
            }
            _ = try advance()
        }
        return info
    }

    private mutating func parseObjectTypeDefinition(description: String?) throws -> ObjectTypeDefinition {
        _ = try advance() // 'type'
        let nameTok = try expect(.name)
        var interfaces: [String] = []
        if peekName("implements") {
            _ = try advance()
            if current.kind == .amp { _ = try advance() }
            interfaces.append(try expect(.name).value)
            while current.kind == .amp {
                _ = try advance()
                interfaces.append(try expect(.name).value)
            }
        }
        let dirs = try parseDirectives(isConst: true)
        var fields: [FieldDefinition] = []
        if current.kind == .brace(open: true) {
            fields = try parseFieldDefinitions()
        }
        return ObjectTypeDefinition(name: nameTok.value, interfaces: interfaces, fields: fields, directives: dirs, description: description)
    }

    private mutating func parseInterfaceTypeDefinition(description: String?) throws -> InterfaceTypeDefinition {
        _ = try advance() // 'interface'
        let nameTok = try expect(.name)
        var interfaces: [String] = []
        if peekName("implements") {
            _ = try advance()
            if current.kind == .amp { _ = try advance() }
            interfaces.append(try expect(.name).value)
            while current.kind == .amp {
                _ = try advance()
                interfaces.append(try expect(.name).value)
            }
        }
        let dirs = try parseDirectives(isConst: true)
        var fields: [FieldDefinition] = []
        if current.kind == .brace(open: true) {
            fields = try parseFieldDefinitions()
        }
        return InterfaceTypeDefinition(name: nameTok.value, interfaces: interfaces, fields: fields, directives: dirs, description: description)
    }

    private mutating func parseFieldDefinitions() throws -> [FieldDefinition] {
        _ = try expect(.brace(open: true))
        var out: [FieldDefinition] = []
        while current.kind != .brace(open: false) {
            let desc = try readDescription()
            let nameTok = try expect(.name)
            var args: [InputValueDefinition] = []
            if current.kind == .paren(open: true) {
                args = try parseInputValueDefinitions()
            }
            _ = try expect(.colon)
            let ty = try parseTypeReference()
            let dirs = try parseDirectives(isConst: true)
            out.append(FieldDefinition(name: nameTok.value, arguments: args, type: ty, directives: dirs, description: desc))
        }
        _ = try advance()
        return out
    }

    private mutating func parseInputValueDefinitions() throws -> [InputValueDefinition] {
        _ = try expect(.paren(open: true))
        var out: [InputValueDefinition] = []
        while current.kind != .paren(open: false) {
            let desc = try readDescription()
            let nameTok = try expect(.name)
            _ = try expect(.colon)
            let ty = try parseTypeReference()
            var def: Value? = nil
            if current.kind == .equals {
                _ = try advance()
                def = try parseValueLiteral(isConst: true)
            }
            let dirs = try parseDirectives(isConst: true)
            out.append(InputValueDefinition(name: nameTok.value, type: ty, defaultValue: def, directives: dirs, description: desc))
        }
        _ = try advance()
        return out
    }

    private mutating func parseUnionTypeDefinition(description: String?) throws -> UnionTypeDefinition {
        _ = try advance() // 'union'
        let nameTok = try expect(.name)
        let dirs = try parseDirectives(isConst: true)
        var types: [String] = []
        if current.kind == .equals {
            _ = try advance()
            if current.kind == .pipe { _ = try advance() }
            types.append(try expect(.name).value)
            while current.kind == .pipe {
                _ = try advance()
                types.append(try expect(.name).value)
            }
        }
        return UnionTypeDefinition(name: nameTok.value, types: types, directives: dirs, description: description)
    }

    private mutating func parseEnumTypeDefinition(description: String?) throws -> EnumTypeDefinition {
        _ = try advance() // 'enum'
        let nameTok = try expect(.name)
        let dirs = try parseDirectives(isConst: true)
        var values: [EnumValueDefinition] = []
        if current.kind == .brace(open: true) {
            _ = try advance()
            while current.kind != .brace(open: false) {
                let desc = try readDescription()
                let vName = try expect(.name).value
                let vDirs = try parseDirectives(isConst: true)
                values.append(EnumValueDefinition(name: vName, directives: vDirs, description: desc))
            }
            _ = try advance()
        }
        return EnumTypeDefinition(name: nameTok.value, values: values, directives: dirs, description: description)
    }

    private mutating func parseScalarTypeDefinition(description: String?) throws -> ScalarTypeDefinition {
        _ = try advance() // 'scalar'
        let nameTok = try expect(.name)
        let dirs = try parseDirectives(isConst: true)
        return ScalarTypeDefinition(name: nameTok.value, directives: dirs, description: description)
    }

    private mutating func parseInputObjectTypeDefinition(description: String?) throws -> InputObjectTypeDefinition {
        _ = try advance() // 'input'
        let nameTok = try expect(.name)
        let dirs = try parseDirectives(isConst: true)
        var fields: [InputValueDefinition] = []
        if current.kind == .brace(open: true) {
            _ = try advance()
            while current.kind != .brace(open: false) {
                let desc = try readDescription()
                let fName = try expect(.name).value
                _ = try expect(.colon)
                let ty = try parseTypeReference()
                var def: Value? = nil
                if current.kind == .equals {
                    _ = try advance()
                    def = try parseValueLiteral(isConst: true)
                }
                let fDirs = try parseDirectives(isConst: true)
                fields.append(InputValueDefinition(name: fName, type: ty, defaultValue: def, directives: fDirs, description: desc))
            }
            _ = try advance()
        }
        return InputObjectTypeDefinition(name: nameTok.value, fields: fields, directives: dirs, description: description)
    }
}
