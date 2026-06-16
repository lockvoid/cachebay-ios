import Foundation

/// Depth-first visitor / transformer for Documents.
/// Action returned by callbacks controls traversal.
public enum VisitAction<T> {
    case keep
    case replace(T)
    case remove
}

public struct Visitor {
    public var enterField: ((Field) -> VisitAction<Field>)?
    public var exitField: ((Field) -> VisitAction<Field>)?
    public var enterInlineFragment: ((InlineFragment) -> VisitAction<InlineFragment>)?
    public var enterFragmentSpread: ((FragmentSpread) -> VisitAction<FragmentSpread>)?

    public init(
        enterField: ((Field) -> VisitAction<Field>)? = nil,
        exitField: ((Field) -> VisitAction<Field>)? = nil,
        enterInlineFragment: ((InlineFragment) -> VisitAction<InlineFragment>)? = nil,
        enterFragmentSpread: ((FragmentSpread) -> VisitAction<FragmentSpread>)? = nil
    ) {
        self.enterField = enterField
        self.exitField = exitField
        self.enterInlineFragment = enterInlineFragment
        self.enterFragmentSpread = enterFragmentSpread
    }

    public func visit(_ document: Document) -> Document {
        var defs: [Definition] = []
        defs.reserveCapacity(document.definitions.count)
        for d in document.definitions {
            switch d {
            case .operation(let op):
                let sels = visit(op.selectionSet)
                defs.append(
                    .operation(
                        OperationDefinition(
                            operation: op.operation,
                            name: op.name,
                            variableDefinitions: op.variableDefinitions,
                            directives: op.directives,
                            selectionSet: sels,
                            location: op.location
                        )))
            case .fragment(let fr):
                let sels = visit(fr.selectionSet)
                defs.append(
                    .fragment(
                        FragmentDefinition(
                            name: fr.name,
                            typeCondition: fr.typeCondition,
                            directives: fr.directives,
                            selectionSet: sels,
                            location: fr.location
                        )))
            case .schema:
                defs.append(d)
            }
        }
        return Document(definitions: defs)
    }

    public func visit(_ selections: [Selection]) -> [Selection] {
        var out: [Selection] = []
        out.reserveCapacity(selections.count)
        for sel in selections {
            switch sel {
            case .field(var f):
                if let action = enterField?(f) {
                    switch action {
                    case .remove: continue
                    case .replace(let r): f = r
                    case .keep: break
                    }
                }
                // recurse into children
                let childSels = visit(f.selectionSet)
                f = Field(
                    alias: f.alias, name: f.name, arguments: f.arguments,
                    directives: f.directives, selectionSet: childSels, location: f.location
                )
                if let action = exitField?(f) {
                    switch action {
                    case .remove: continue
                    case .replace(let r): out.append(.field(r))
                    case .keep: out.append(.field(f))
                    }
                } else {
                    out.append(.field(f))
                }
            case .inlineFragment(var ifr):
                if let action = enterInlineFragment?(ifr) {
                    switch action {
                    case .remove: continue
                    case .replace(let r): ifr = r
                    case .keep: break
                    }
                }
                let childSels = visit(ifr.selectionSet)
                ifr = InlineFragment(typeCondition: ifr.typeCondition, directives: ifr.directives, selectionSet: childSels, location: ifr.location)
                out.append(.inlineFragment(ifr))
            case .fragmentSpread(let sp):
                if let action = enterFragmentSpread?(sp) {
                    switch action {
                    case .remove: continue
                    case .replace(let r): out.append(.fragmentSpread(r))
                    case .keep: out.append(sel)
                    }
                } else {
                    out.append(sel)
                }
            }
        }
        return out
    }
}
