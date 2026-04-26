import Foundation
import CachebayGraphQL

/// `QueryDocument` is the union the public API accepts: pre-compiled plan or
/// raw GraphQL source string. Parsed AST is an implementation detail of the
/// compiler for now; callers either hold a plan or a string.
public enum QueryDocument: Sendable, Hashable {
    case plan(CachePlan)
    case source(String)

    public static func == (lhs: QueryDocument, rhs: QueryDocument) -> Bool {
        switch (lhs, rhs) {
        case let (.plan(a), .plan(b)): return a == b
        case let (.source(a), .source(b)): return a == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .plan(let p): hasher.combine(0); hasher.combine(p)
        case .source(let s): hasher.combine(1); hasher.combine(s)
        }
    }
}

/// Memoises plan compilation per (source, fragmentName) pair. Used internally
/// by every public operation entry point.
public final class Planner: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: CachePlan] = [:]

    public init() {}

    public func getPlan(_ doc: QueryDocument, fragmentName: String? = nil) throws -> CachePlan {
        switch doc {
        case .plan(let p): return p
        case .source(let s):
            let key = (fragmentName.map { "\($0)::" } ?? "::") + s
            lock.lock()
            if let hit = cache[key] {
                lock.unlock()
                return hit
            }
            lock.unlock()
            let plan = try Compiler.compilePlan(source: s, fragmentName: fragmentName)
            lock.lock()
            cache[key] = plan
            lock.unlock()
            return plan
        }
    }

    public func evictAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll(keepingCapacity: false)
    }
}
