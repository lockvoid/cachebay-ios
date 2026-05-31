// The proposal's canonical interface example: an `Element` interface with
// video/audio/image variants, nested inside the enum (the namespace/nesting canary).

import Foundation
import Cachebay
import CachebayMacros

@CachebayInterface
enum Element: Identifiable, Sendable, Hashable, CachebayValue {
    case video(Video)
    case audio(Audio)
    case image(Image)
    case unknown(Shared)

    /// Interface-level shared fields carried by every variant incl. `.unknown` (§3.1).
    @CachebayData(typename: "")
    struct Shared: Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
    }

    @CachebayData(typename: "VideoElement")
    struct Video: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let url: URL
        let duration: TimeInterval
    }

    @CachebayData(typename: "AudioElement")
    struct Audio: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let waveformURL: URL
    }

    @CachebayData(typename: "ImageElement")
    struct Image: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let thumbnailURL: URL
    }
}
