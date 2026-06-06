import Foundation

public enum CachebayConstants {
    public static let rootID: CacheKey = "@"
    public static let idField = "id"
    public static let typenameField = "__typename"

    public static let connectionDirective = "connection"
    public static let connectionEdgesField = "edges"
    public static let connectionPageInfoField = "pageInfo"
    public static let connectionNodeField = "node"
    public static let connectionFirstField = "first"
    public static let connectionLastField = "last"
    public static let connectionAfterField = "after"
    public static let connectionBeforeField = "before"

    /// Reserved field on a connection canonical recording its edge type name
    /// (e.g. "QueryProjectsConnectionEdge"), stamped from the schema-derived plan
    /// when the connection is normalized. Lets an optimistic `insertEdge` give its
    /// synthetic edge the AUTHORITATIVE edge `__typename` — even for an empty
    /// connection where there's no sibling edge to copy from. Not part of the
    /// materialized shape (materialize reads only `edges`/`pageInfo`).
    public static let connectionEdgeTypenameField = "__edgeTypename"

    public static let connectionModeInfinite = "infinite"
    public static let connectionModePage = "page"
    public static let connectionTypename = "Connection"
    public static let connectionPageInfoTypename = "PageInfo"

    public static let paginationArgs: Set<String> = ["first", "last", "after", "before"]

    /// Special field marker key used by materialize() fingerprint emission.
    public static let fingerprintKey = "__version"
}

public enum CachePolicy: String, Hashable, Sendable, CaseIterable {
    case cacheAndNetwork = "cache-and-network"
    case networkOnly = "network-only"
    case cacheFirst = "cache-first"
    case cacheOnly = "cache-only"
}
