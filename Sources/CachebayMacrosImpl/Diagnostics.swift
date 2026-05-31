import SwiftDiagnostics

/// Diagnostics emitted by the Cachebay macros. Clear messages are a deliberate
/// mitigation for opaque macro failure modes (proposal Risk #2).
enum CachebayMacroDiagnostic: String, DiagnosticMessage {
    case dataOnlyOnStruct
    case dataMissingTypename
    case interfaceOnlyOnEnum

    var message: String {
        switch self {
        case .dataOnlyOnStruct:
            return "@CachebayData can only be applied to a struct."
        case .dataMissingTypename:
            return "@CachebayData requires a 'typename:' argument (use \"\" for an interface's Shared struct)."
        case .interfaceOnlyOnEnum:
            return "@CachebayInterface/@CachebayUnion can only be applied to an enum."
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "CachebayMacros", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }
}
