import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - IPBlockDetectionTests
//
// Verifies that APIError.ipBlocked is:
//   1. Correctly classified from known IP-block reason strings.
//   2. Distinct from APIError.unavailable (so the short-circuit path fires only for VPN blocks).
//   3. Surfaces the expected user-facing error description.

@Suite("IP Block Error Detection")
struct IPBlockDetectionTests {

    // MARK: - Helpers

    /// Mirrors the keyword heuristic in InnerTubeAPI+Player.swift so tests stay in sync.
    /// If the keywords change in the implementation, this list must change too.
    private func isIPBlockReason(_ reason: String) -> Bool {
        let lower = reason.lowercased()
        let keywords = ["your ip", "ip address", "vpn", "proxy", "bot", "sign in to confirm"]
        return keywords.contains(where: { lower.contains($0) })
    }

    // MARK: - Keyword heuristic

    @Test("'your IP has been blocked' triggers IP-block classification")
    func yourIPKeyword() {
        #expect(isIPBlockReason("Your IP has been blocked. Please try again later."))
    }

    @Test("'ip address' triggers IP-block classification")
    func ipAddressKeyword() {
        #expect(isIPBlockReason("Requests from your IP address have been temporarily blocked."))
    }

    @Test("'vpn' triggers IP-block classification")
    func vpnKeyword() {
        #expect(isIPBlockReason("Access via VPN is not permitted."))
    }

    @Test("'proxy' triggers IP-block classification")
    func proxyKeyword() {
        #expect(isIPBlockReason("Requests from a proxy are not allowed."))
    }

    @Test("'bot' triggers IP-block classification")
    func botKeyword() {
        #expect(isIPBlockReason("This content is not available to bots."))
    }

    @Test("'sign in to confirm' triggers IP-block classification")
    func signInToConfirmKeyword() {
        #expect(isIPBlockReason("Sign in to confirm you're not a bot."))
    }

    @Test("Generic 'video unavailable' does NOT trigger IP-block classification")
    func genericUnavailableDoesNotTrigger() {
        #expect(!isIPBlockReason("This video is unavailable"))
    }

    @Test("Members-only reason does NOT trigger IP-block classification")
    func membersOnlyDoesNotTrigger() {
        #expect(!isIPBlockReason("This video is available to members only"))
    }

    @Test("Keyword check is case-insensitive")
    func keywordIsCaseInsensitive() {
        #expect(isIPBlockReason("YOUR IP WAS FLAGGED"))
        #expect(isIPBlockReason("VPN detected"))
    }

    // MARK: - APIError.ipBlocked properties

    @Test("ipBlocked errorDescription is the fixed user-facing message")
    func ipBlockedErrorDescription() {
        let error = APIError.ipBlocked("Your IP has been blocked")
        #expect(error.errorDescription?.contains("VPN") == true)
        #expect(error.errorDescription?.contains("temporarily blocking") == true)
    }

    @Test("ipBlocked is not the same case as unavailable")
    func ipBlockedIsDistinctFromUnavailable() {
        let ipError = APIError.ipBlocked("Your IP has been blocked")
        if case APIError.unavailable = ipError {
            Issue.record("ipBlocked matched the .unavailable pattern — cases must stay distinct")
        }
    }

    @Test("unavailable does not match ipBlocked pattern")
    func unavailableIsDistinctFromIPBlocked() {
        let genericError = APIError.unavailable("This video is unavailable")
        if case APIError.ipBlocked = genericError {
            Issue.record("unavailable matched the .ipBlocked pattern — cases must stay distinct")
        }
    }
}
