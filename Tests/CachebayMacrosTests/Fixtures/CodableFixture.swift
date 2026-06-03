// A `@CachebayData` value that opts into `Codable` — mirrors a derivative leaf
// payload (e.g. `AudioEvents`) the analyzer persists to an on-disk blob and reads
// back without a server round-trip. Exercises the macro-emitted Codable:
// `@CachebayDefault` honored on decode, optionals tolerated, GraphQLEnum + nested
// struct fields, wire-key naming.

import Foundation
import Cachebay

enum DerivativeKind: String, Sendable, Hashable, CaseIterable, Codable {
    case audio = "AUDIO"
    case video = "VIDEO"
}

@CachebayData(typename: "AudioEvents")
struct CodableAudioEvents: Sendable, Hashable, Codable, CachebayValue {
    let __typename: String
    let id: String
    @CachebayDefault("a0") let rank: String
    let bpm: Double
    let kind: GraphQLEnum<DerivativeKind>
    let summary: String?
    let tags: [String]
    let beatGrid: CodableBeatGrid?
}

@CachebayData(typename: "BeatGrid")
struct CodableBeatGrid: Sendable, Hashable, Codable, CachebayValue {
    let __typename: String
    let id: String
    let coverage: Double
    let downbeats: [Double]
}
