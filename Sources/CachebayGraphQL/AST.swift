import Foundation

/// GraphQL AST nodes. A compact subset covering queries, mutations, subscriptions,
/// fragments, inline fragments, directives, arguments, and type references (used
/// for SDL parsing and variable-definition typing).
///
/// Source locations are byte offsets into the original input; zero for synthesized nodes.

public struct SourceLocation: Hashable, Sendable {
    public let start: Int
    public let end: Int
    public let line: Int
    public let column: Int

    public init(start: Int, end: Int, line: Int, column: Int) {
        self.start = start
        self.end = end
        self.line = line
        self.column = column
    }

    public static let zero = SourceLocation(start: 0, end: 0, line: 0, column: 0)
}

public indirect enum TypeReference: Hashable, Sendable {
    case named(String)
    case list(TypeReference)
    case nonNull(TypeReference)

    public var namedType: String {
        switch self {
        case .named(let name): return name
        case .list(let inner), .nonNull(let inner): return inner.namedType
        }
    }

    public var isNonNull: Bool {
        if case .nonNull = self { return true }
        return false
    }
}

public indirect enum Value: Hashable, Sendable {
    case variable(String)
    case int(Int64)
    case float(Double)
    case string(String)
    case boolean(Bool)
    case null
    case `enum`(String)
    case list([Value])
    case object([ObjectField])
}

public struct ObjectField: Hashable, Sendable {
    public let name: String
    public let value: Value
    public init(name: String, value: Value) {
        self.name = name
        self.value = value
    }
}

public struct Argument: Hashable, Sendable {
    public let name: String
    public let value: Value
    public let location: SourceLocation
    public init(name: String, value: Value, location: SourceLocation = .zero) {
        self.name = name
        self.value = value
        self.location = location
    }
}

public struct Directive: Hashable, Sendable {
    public let name: String
    public let arguments: [Argument]
    public let location: SourceLocation
    public init(name: String, arguments: [Argument] = [], location: SourceLocation = .zero) {
        self.name = name
        self.arguments = arguments
        self.location = location
    }
}

public struct VariableDefinition: Hashable, Sendable {
    public let name: String
    public let type: TypeReference
    public let defaultValue: Value?
    public let directives: [Directive]
    public let location: SourceLocation
    public init(name: String, type: TypeReference, defaultValue: Value? = nil, directives: [Directive] = [], location: SourceLocation = .zero) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.directives = directives
        self.location = location
    }
}

public enum Selection: Hashable, Sendable {
    case field(Field)
    case inlineFragment(InlineFragment)
    case fragmentSpread(FragmentSpread)
}

public struct Field: Hashable, Sendable {
    public let alias: String?
    public let name: String
    public let arguments: [Argument]
    public let directives: [Directive]
    public let selectionSet: [Selection]
    public let location: SourceLocation

    public var responseKey: String { alias ?? name }

    public init(
        alias: String? = nil,
        name: String,
        arguments: [Argument] = [],
        directives: [Directive] = [],
        selectionSet: [Selection] = [],
        location: SourceLocation = .zero
    ) {
        self.alias = alias
        self.name = name
        self.arguments = arguments
        self.directives = directives
        self.selectionSet = selectionSet
        self.location = location
    }
}

public struct InlineFragment: Hashable, Sendable {
    public let typeCondition: String?
    public let directives: [Directive]
    public let selectionSet: [Selection]
    public let location: SourceLocation

    public init(typeCondition: String? = nil, directives: [Directive] = [], selectionSet: [Selection] = [], location: SourceLocation = .zero) {
        self.typeCondition = typeCondition
        self.directives = directives
        self.selectionSet = selectionSet
        self.location = location
    }
}

public struct FragmentSpread: Hashable, Sendable {
    public let name: String
    public let directives: [Directive]
    public let location: SourceLocation

    public init(name: String, directives: [Directive] = [], location: SourceLocation = .zero) {
        self.name = name
        self.directives = directives
        self.location = location
    }
}

public enum OperationKind: String, Hashable, Sendable {
    case query
    case mutation
    case subscription
}

public struct OperationDefinition: Hashable, Sendable {
    public let operation: OperationKind
    public let name: String?
    public let variableDefinitions: [VariableDefinition]
    public let directives: [Directive]
    public let selectionSet: [Selection]
    public let location: SourceLocation

    public init(
        operation: OperationKind,
        name: String? = nil,
        variableDefinitions: [VariableDefinition] = [],
        directives: [Directive] = [],
        selectionSet: [Selection],
        location: SourceLocation = .zero
    ) {
        self.operation = operation
        self.name = name
        self.variableDefinitions = variableDefinitions
        self.directives = directives
        self.selectionSet = selectionSet
        self.location = location
    }
}

public struct FragmentDefinition: Hashable, Sendable {
    public let name: String
    public let typeCondition: String
    public let directives: [Directive]
    public let selectionSet: [Selection]
    public let location: SourceLocation

    public init(name: String, typeCondition: String, directives: [Directive] = [], selectionSet: [Selection] = [], location: SourceLocation = .zero) {
        self.name = name
        self.typeCondition = typeCondition
        self.directives = directives
        self.selectionSet = selectionSet
        self.location = location
    }
}

public enum Definition: Hashable, Sendable {
    case operation(OperationDefinition)
    case fragment(FragmentDefinition)
    case schema(SchemaDefinition)
}

public struct Document: Hashable, Sendable {
    public var definitions: [Definition]
    public init(definitions: [Definition]) { self.definitions = definitions }

    public var operations: [OperationDefinition] {
        definitions.compactMap { if case .operation(let op) = $0 { return op } else { return nil } }
    }

    public var fragments: [FragmentDefinition] {
        definitions.compactMap { if case .fragment(let f) = $0 { return f } else { return nil } }
    }

    public var fragmentsByName: [String: FragmentDefinition] {
        var out: [String: FragmentDefinition] = [:]
        for f in fragments { out[f.name] = f }
        return out
    }
}

// MARK: - Schema Definition Language (SDL) nodes

public struct FieldDefinition: Hashable, Sendable {
    public let name: String
    public let arguments: [InputValueDefinition]
    public let type: TypeReference
    public let directives: [Directive]
    public let description: String?
    public init(name: String, arguments: [InputValueDefinition] = [], type: TypeReference, directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.type = type
        self.directives = directives
        self.description = description
    }
}

public struct InputValueDefinition: Hashable, Sendable {
    public let name: String
    public let type: TypeReference
    public let defaultValue: Value?
    public let directives: [Directive]
    public let description: String?
    public init(name: String, type: TypeReference, defaultValue: Value? = nil, directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.directives = directives
        self.description = description
    }
}

public enum TypeDefinition: Hashable, Sendable {
    case object(ObjectTypeDefinition)
    case interface(InterfaceTypeDefinition)
    case union(UnionTypeDefinition)
    case `enum`(EnumTypeDefinition)
    case scalar(ScalarTypeDefinition)
    case inputObject(InputObjectTypeDefinition)

    public var name: String {
        switch self {
        case .object(let t): return t.name
        case .interface(let t): return t.name
        case .union(let t): return t.name
        case .enum(let t): return t.name
        case .scalar(let t): return t.name
        case .inputObject(let t): return t.name
        }
    }
}

public struct ObjectTypeDefinition: Hashable, Sendable {
    public let name: String
    public let interfaces: [String]
    public let fields: [FieldDefinition]
    public let directives: [Directive]
    public let description: String?
    public init(name: String, interfaces: [String] = [], fields: [FieldDefinition] = [], directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.interfaces = interfaces
        self.fields = fields
        self.directives = directives
        self.description = description
    }
}

public struct InterfaceTypeDefinition: Hashable, Sendable {
    public let name: String
    public let interfaces: [String]
    public let fields: [FieldDefinition]
    public let directives: [Directive]
    public let description: String?
    public init(name: String, interfaces: [String] = [], fields: [FieldDefinition] = [], directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.interfaces = interfaces
        self.fields = fields
        self.directives = directives
        self.description = description
    }
}

public struct UnionTypeDefinition: Hashable, Sendable {
    public let name: String
    public let types: [String]
    public let directives: [Directive]
    public let description: String?
    public init(name: String, types: [String] = [], directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.types = types
        self.directives = directives
        self.description = description
    }
}

public struct EnumValueDefinition: Hashable, Sendable {
    public let name: String
    public let directives: [Directive]
    public let description: String?
    public init(name: String, directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.directives = directives
        self.description = description
    }
}

public struct EnumTypeDefinition: Hashable, Sendable {
    public let name: String
    public let values: [EnumValueDefinition]
    public let directives: [Directive]
    public let description: String?
    public init(name: String, values: [EnumValueDefinition] = [], directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.values = values
        self.directives = directives
        self.description = description
    }
}

public struct ScalarTypeDefinition: Hashable, Sendable {
    public let name: String
    public let directives: [Directive]
    public let description: String?
    public init(name: String, directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.directives = directives
        self.description = description
    }
}

public struct InputObjectTypeDefinition: Hashable, Sendable {
    public let name: String
    public let fields: [InputValueDefinition]
    public let directives: [Directive]
    public let description: String?
    public init(name: String, fields: [InputValueDefinition] = [], directives: [Directive] = [], description: String? = nil) {
        self.name = name
        self.fields = fields
        self.directives = directives
        self.description = description
    }
}

public struct SchemaDefinition: Hashable, Sendable {
    public let types: [TypeDefinition]
    public let queryType: String?
    public let mutationType: String?
    public let subscriptionType: String?

    public init(types: [TypeDefinition], queryType: String? = nil, mutationType: String? = nil, subscriptionType: String? = nil) {
        self.types = types
        self.queryType = queryType
        self.mutationType = mutationType
        self.subscriptionType = subscriptionType
    }
}
