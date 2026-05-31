// Hand-written example operation types — the v1.0 macro spike target.
// In production these are CLI-emitted; here they exercise the macros end-to-end.
//
// Conformances are declared on the type (compiler-synthesizes Equatable/Hashable/
// Codable from the stored `let`s); the macro provides the member surface
// (memberwise init, eager `init?(_dataDict:)`, `__dataDict()`, `CachebayValue`).

import Foundation
import Cachebay

@CachebayData(typename: "Tag")
struct Tag: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let label: String
}

@CachebayData(typename: "VideoElement")
struct Video: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let url: URL
    let duration: TimeInterval
    @CachebayDefault("a0") let rank: String
    let intent: String?
}

@CachebayData(typename: "Cook")
struct Cook: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let title: String
    let tags: [Tag]
    let hero: Video?
}
