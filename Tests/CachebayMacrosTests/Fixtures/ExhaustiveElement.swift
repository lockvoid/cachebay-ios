import Foundation
import Cachebay

/// Mirrors what `cachebay-cli` emits for an interface selection under
/// `polymorphism.exhaustive` — a case per schema implementor, where a
/// **non-selected** implementor (`AudioElement` here) carries only the interface
/// fields with its typename **pinned** by the macro. `.unknown(Shared)` stays for
/// typenames outside the schema snapshot.
///
/// Hand-written because the smoke fixtures' source `.graphql` is gone; the shape
/// is the exact end-to-end output verified against the real ferment `Element`
/// interface (`videoElement` selected, `audioElement` not).
@CachebayInterface
enum ExhaustiveElement: Identifiable, Sendable, Hashable, CachebayValue {
    case videoElement(VideoElement)  // selected: carries a variant-only field
    case audioElement(AudioElement)  // NOT selected: interface fields only
    case unknown(Shared)

    @CachebayData(typename: "")
    struct Shared: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
    }

    @CachebayData(typename: "VideoElement")
    struct VideoElement: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let url: String
    }

    @CachebayData(typename: "AudioElement")
    struct AudioElement: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
    }
}
