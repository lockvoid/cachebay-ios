import XCTest
import Ably
@testable import CachebayAbly

/// The pure half of the continuity-loss reconnect logic: the decision of whether
/// a channel state change should re-register a (presence-reaped) subscription.
/// The live wiring half (channel swap, presence enter/leave, retry) is
/// integration-tested against a real Ably client.
final class AblyReconnectTests: XCTestCase {

    // MARK: - Re-register on continuity-loss reattach (the bug this fixes)

    func test_reattach_resumedFalse_afterFirstAttach_onPresenceBackend_reregisters() {
        // >2min suspend → reconnect → channel reattaches without continuity, and
        // a presence backend (GraphQL Pro) has reaped the subscription. Recover.
        XCTAssertTrue(AblyTransport.shouldReregister(
            maintainsPresence: true, hasAttachedBefore: true, current: .attached, resumed: false))
    }

    // MARK: - Cases that must NOT re-register

    func test_initialAttach_doesNotReregister() {
        // The very first attach is always `resumed == false`; it's normal setup,
        // not a continuity loss — `hasAttachedBefore` is still false.
        XCTAssertFalse(AblyTransport.shouldReregister(
            maintainsPresence: true, hasAttachedBefore: false, current: .attached, resumed: false))
    }

    func test_reattach_resumedTrue_doesNotReregister() {
        // <2min blip: continuity preserved, presence intact server-side, queued
        // messages replayed — nothing to do.
        XCTAssertFalse(AblyTransport.shouldReregister(
            maintainsPresence: true, hasAttachedBefore: true, current: .attached, resumed: true))
    }

    func test_nonPresenceBackend_neverReregisters() {
        // Plain pub/sub: continuity loss means missed messages (Ably's concern),
        // not a reaped subscription. Re-registering would create a needless new
        // server resource.
        XCTAssertFalse(AblyTransport.shouldReregister(
            maintainsPresence: false, hasAttachedBefore: true, current: .attached, resumed: false))
    }

    func test_nonAttachedStates_neverReregister() {
        // Only the `attached` transition carries the meaningful `resumed` flag.
        for state in [ARTRealtimeChannelState.initialized, .attaching, .detaching,
                      .detached, .suspended, .failed] {
            XCTAssertFalse(
                AblyTransport.shouldReregister(
                    maintainsPresence: true, hasAttachedBefore: true, current: state, resumed: false),
                "state \(state.rawValue) must not trigger re-registration")
        }
    }
}
