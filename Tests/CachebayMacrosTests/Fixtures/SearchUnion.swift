// A GraphQL union: no shared fields beyond __typename. `@CachebayUnion` lifts only
// __typename; member-specific fields are reached by pattern matching.

import Foundation
import Cachebay
import CachebayMacros

@CachebayUnion
enum SearchResult: Sendable, Hashable, CachebayValue {
    case video(Video)
    case article(Article)
    case unknown(Shared)

    @CachebayData(typename: "")
    struct Shared: Sendable, Hashable, CachebayValue {
        let __typename: String
    }

    @CachebayData(typename: "Video")
    struct Video: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let url: URL
    }

    @CachebayData(typename: "Article")
    struct Article: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let title: String
    }
}
