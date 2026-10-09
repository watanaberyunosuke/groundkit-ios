import Foundation
import Testing
@testable import GroundKit

private func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

struct SyncedSettingsTests {
    @Test func changeStampsAndQueuesTheKey() {
        var s = SyncedSettings()
        s.change(.gloveMode, to: .bool(true), now: date("2026-10-09T10:00:00Z"))
        s.change(.gloveMode, to: .bool(false), now: date("2026-10-09T10:01:00Z"))
        #expect(s[.gloveMode] == .bool(false))
        #expect(s.pending == ["gloveMode"])
        #expect(s.stamps["gloveMode"] == "2026-10-09T10:01:00.000Z")
    }

    @Test func patchSendsPendingKeysAndNullForRemoved() throws {
        var s = SyncedSettings()
        s.change(.airport, to: .string("YSSY"), now: date("2026-10-09T10:00:00Z"))
        s.change(.dashboardLayout, to: nil, now: date("2026-10-09T10:00:00Z"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.patch)) as! [String: Any]
        let patch = json["patch"] as! [String: Any]
        #expect(patch["airport"] as? String == "YSSY")
        #expect(patch["dashboardLayout"] is NSNull)
        #expect((json["patch_stamps"] as! [String: String])["airport"] == "2026-10-09T10:00:00.000Z")
    }

    @Test func adoptTakesTheServerButKeepsKeysChangedInFlight() {
        var s = SyncedSettings()
        s.change(.airport, to: .string("YSSY"), now: date("2026-10-09T10:00:00Z"))
        s.change(.gloveMode, to: .bool(true), now: date("2026-10-09T10:00:00Z"))
        let sent = s.patch.patchStamps
        s.change(.gloveMode, to: .bool(false), now: date("2026-10-09T10:00:05Z")) // while the request was out
        let server = MergeResponse(
            settings: ["airport": .string("VHHH"), "gloveMode": .bool(true), "keepAwake": .bool(true),
                       "futureKey": .string("x"), "windCautionKt": .int(500)],
            stamps: ["airport": "2026-10-09T11:00:00Z", "gloveMode": "2026-10-09T10:00:00Z"])
        let next = s.adopting(server, sent: sent)
        #expect(next[.airport] == .string("VHHH")) // newer on the server
        #expect(next[.keepAwake] == .bool(true))
        #expect(next[.gloveMode] == .bool(false)) // changed again locally, still pending
        #expect(next.pending == ["gloveMode"])
        #expect(next.values["futureKey"] == nil) // unknown keys are not kept locally
        #expect(next[.windCautionKt] == nil) // out of range
    }

    @Test func decodesMixedValuesAndSkipsUnknownShapes() throws {
        let data = Data(#"{"settings": {"gloveMode": true, "windCautionKt": 30, "airport": "YMML", "x": [1]}, "stamps": {}, "updated_at": "2026-10-09T10:00:00Z"}"#.utf8)
        let r = try JSONDecoder().decode(MergeResponse.self, from: data)
        #expect(r.settings["gloveMode"] == .bool(true))
        #expect(r.settings["windCautionKt"] == .int(30))
        #expect(r.settings["airport"] == .string("YMML"))
        #expect(r.settings["x"] == nil)
    }

    @Test func validatesValues() {
        #expect(SettingKey.airport.isValid(.string("VHHH")))
        #expect(!SettingKey.airport.isValid(.string("vhhh")))
        #expect(SettingKey.appearance.isValid(.string("sunset")))
        #expect(!SettingKey.dashboardTheme.isValid(.string("sunset")))
        #expect(!SettingKey.windWarningKt.isValid(.bool(true)))
    }
}

struct SupabaseClientTests {
    @Test func pkceChallengeIsS256OfTheVerifier() {
        // Computed independently: base64url(sha256("groundkit-test-verifier-0123456789")).
        #expect(PKCE(verifier: "groundkit-test-verifier-0123456789").challenge == "GyP7CMiaHVef476T4-n7UMZoJIW3AoyTFgku4Gc-vew")
        #expect(PKCE.sha256Hex("nonce-abc") == "519d6dcd2eb87278bb61c6814cff01262b8c7e2d2c93124798ac89bcb3723a34")
        #expect(PKCE.random().count == 43)
    }

    @Test func authorizeURLCarriesTheChallenge() {
        let client = SupabaseClient(config: SupabaseConfig(url: URL(string: "https://abc.supabase.co")!, key: "k"))
        let url = client.authorizeURL(provider: "azure", pkce: PKCE(verifier: "groundkit-test-verifier-0123456789"), scopes: "email")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        #expect(url.path == "/auth/v1/authorize")
        #expect(q["provider"] == "azure")
        #expect(q["redirect_to"] == "groundkit://auth-callback")
        #expect(q["code_challenge"] == "GyP7CMiaHVef476T4-n7UMZoJIW3AoyTFgku4Gc-vew")
        #expect(q["code_challenge_method"] == "s256")
        #expect(q["scopes"] == "email")
    }

    @Test func readsTheCallback() throws {
        #expect(try SupabaseClient.code(fromCallback: URL(string: "groundkit://auth-callback?code=abc")!) == "abc")
        #expect(throws: SupabaseError.self) {
            try SupabaseClient.code(fromCallback: URL(string: "groundkit://auth-callback#error=access_denied&error_description=Denied")!)
        }
    }

    @Test func decodesASession() throws {
        let data = Data(#"""
        {"access_token": "a", "token_type": "bearer", "expires_in": 3600, "expires_at": 1791000000, "refresh_token": "r",
         "user": {"id": "u1", "email": "ada@example.com", "identities": [{"provider": "google"}, {"provider": "google"}]}}
        """#.utf8)
        let s = try SupabaseClient.decodeSession(data)
        #expect(s.accessToken == "a" && s.refreshToken == "r")
        #expect(s.expiresAt == Date(timeIntervalSince1970: 1_791_000_000))
        #expect(s.user.providers == ["google"])
        #expect(s.needsRefresh(at: Date(timeIntervalSince1970: 1_790_999_950)))
        #expect(!s.needsRefresh(at: Date(timeIntervalSince1970: 1_790_990_000)))
    }

    @Test func mapsErrors() {
        let auth = SupabaseClient.error(status: 400, data: Data(#"{"error_code": "invalid_credentials", "msg": "Invalid login credentials"}"#.utf8))
        #expect(auth.code == "invalid_credentials")
        #expect(auth.message == "That email and password do not match an account.")
        let rest = SupabaseClient.error(status: 401, data: Data(#"{"code": "42501", "message": "Sign in to sync settings"}"#.utf8))
        #expect(rest.isSignedOut)
        #expect(SupabaseClient.error(status: 400, data: Data(#"{"error_code": "refresh_token_not_found", "msg": "x"}"#.utf8)).isSignedOut)
    }
}
