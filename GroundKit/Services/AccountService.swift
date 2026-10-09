import Foundation
import Observation

/// The optional GroundKit account: sign-in state and settings sync. Signed out, the app
/// works as before. Signed in, the settings in `SettingsBridge` sync with the Android app and
/// the web dashboard. Age and the API address stay on this device.
@Observable
final class AccountService {
    let config: SupabaseConfig?
    private(set) var session: AuthSession?
    private(set) var displayName: String?
    private(set) var syncing = false
    private(set) var syncError: String?
    private(set) var settings: SyncedSettings

    var isConfigured: Bool { config != nil }
    var user: AuthUser? { session?.user }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var bridge: SettingsBridge?
    @ObservationIgnored private var lastSeen: [SettingKey: SettingValue] = [:]
    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<AuthSession, Error>?
    @ObservationIgnored private var lastSync: Date = .distantPast
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let settingsKey = "syncedSettings"
    private var client: SupabaseClient? { config.map { SupabaseClient(config: $0) } }

    init(config: SupabaseConfig? = .fromBundle(), defaults: UserDefaults = .standard) {
        self.config = config
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(SyncedSettings.self, from: $0) } ?? SyncedSettings()
        session = config == nil ? nil : Keychain.load()
    }

    /// Starts watching the app's settings. Call once, with the app's AirportStore.
    func attach(_ store: AirportStore) {
        guard bridge == nil else { return }
        let bridge = SettingsBridge(store: store, defaults: defaults)
        self.bridge = bridge
        lastSeen = bridge.read()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detectLocalChanges() }
        }
        if session != nil {
            Task {
                await loadProfile()
                await sync()
            }
        }
    }

    // MARK: Sign in

    func signIn(email: String, password: String) async throws {
        guard let client else { return }
        await didSignIn(try await client.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password))
    }

    /// True when signed in straight away; false when the address needs confirming first.
    func signUp(email: String, password: String, displayName: String) async throws -> Bool {
        guard let client else { return false }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = try await client.signUp(email: email.trimmingCharacters(in: .whitespaces), password: password,
                                              displayName: name.isEmpty ? nil : name) else { return false }
        await didSignIn(s)
        return true
    }

    /// Apple sends the person's name only on their first sign-in, and only to the app.
    func signInWithApple(idToken: String, rawNonce: String, fullName: String?) async throws {
        guard let client else { return }
        let s = try await client.signInWithApple(idToken: idToken, rawNonce: rawNonce)
        await didSignIn(s)
        if let fullName, !fullName.isEmpty, displayName == nil { try? await saveDisplayName(fullName) }
    }

    func providerStart(_ provider: AuthProvider) -> (url: URL, pkce: PKCE)? {
        guard let client else { return nil }
        let pkce = PKCE()
        return (client.authorizeURL(provider: provider.rawValue, pkce: pkce, scopes: provider.scopes), pkce)
    }

    func providerFinish(callback: URL, pkce: PKCE) async throws {
        guard let client else { return }
        await didSignIn(try await client.exchange(code: try SupabaseClient.code(fromCallback: callback), pkce: pkce))
    }

    func resetPassword(email: String) async throws {
        try await client?.resetPassword(email: email.trimmingCharacters(in: .whitespaces))
    }

    func signOut() async {
        if let s = session { try? await client?.signOut(s) }
        clearSession()
    }

    /// Deletes the account, profile and synced settings. Settings on this device stay.
    func deleteAccount() async throws {
        guard let client else { return }
        try await client.deleteAccount(token: try await validToken())
        clearSession()
    }

    func saveDisplayName(_ name: String) async throws {
        guard let client, let user else { return }
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        try await client.setDisplayName(value.isEmpty ? nil : value, userID: user.id, token: try await validToken())
        displayName = value.isEmpty ? nil : value
    }

    // MARK: Sync

    /// Sends pending changes (or none, which just fetches) and applies the merged result.
    /// `ifStale` skips it when the last sync was under a minute ago (foregrounding).
    func sync(ifStale: Bool = false) async {
        guard let client, session != nil, !syncing else { return }
        if ifStale && Date.now.timeIntervalSince(lastSync) < 60 { return }
        syncing = true
        defer { syncing = false }
        let request = settings.patch
        do {
            let response = try await client.mergeSettings(request, token: try await validToken())
            lastSync = .now
            syncError = nil
            store(settings.adopting(response, sent: request.patchStamps))
            applyRemote()
        } catch let e as SupabaseError where e.isSignedOut {
            clearSession()
        } catch {
            syncError = error.localizedDescription
        }
        if !settings.pending.isEmpty && syncError == nil { scheduleSync() }
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Compares the app's settings with the last seen values; changed ones become pending.
    private func detectLocalChanges() {
        guard let bridge, !applyingRemote else { return }
        let now = bridge.read()
        guard now != lastSeen else { return }
        var next = settings
        for key in SettingsBridge.keys where now[key] != lastSeen[key] {
            next.change(key, to: now[key])
        }
        lastSeen = now
        store(next)
        if session != nil { scheduleSync() }
    }

    private func applyRemote() {
        guard let bridge else { return }
        applyingRemote = true
        bridge.apply(settings)
        lastSeen = bridge.read()
        applyingRemote = false
    }

    private func store(_ next: SyncedSettings) {
        settings = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.settingsKey) }
    }

    // MARK: Session

    private func didSignIn(_ s: AuthSession) async {
        session = s
        Keychain.save(s)
        // Settings changed before this version had no stamps: offer them with the oldest
        // possible stamp, so the account's value wins where it has one.
        if let bridge {
            var next = settings
            for (key, value) in bridge.read() where next.stamps[key.rawValue] == nil && value != bridge.defaultValue(key) {
                next.values[key.rawValue] = value
                next.stamps[key.rawValue] = SyncedSettings.stamp(Date(timeIntervalSince1970: 0))
                if !next.pending.contains(key.rawValue) { next.pending.append(key.rawValue) }
            }
            store(next)
        }
        await loadProfile()
        await sync()
    }

    private func loadProfile() async {
        guard let client, let user else { return }
        if let token = try? await validToken() {
            displayName = (try? await client.displayName(userID: user.id, token: token)) ?? displayName
        }
    }

    private func clearSession() {
        syncTask?.cancel()
        session = nil
        displayName = nil
        syncError = nil
        Keychain.save(nil)
        var next = settings
        next.pending = []
        store(next)
    }

    /// A current access token, refreshing it (once, however many callers wait) when due.
    private func validToken() async throws -> String {
        guard let client, let s = session else { throw SupabaseError(status: 401, code: nil, message: "Not signed in.") }
        if !s.needsRefresh() { return s.accessToken }
        let task = refreshTask ?? Task { try await client.refresh(s.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            session = fresh
            Keychain.save(fresh)
            return fresh.accessToken
        } catch let e as SupabaseError where e.isSignedOut || e.status == 400 {
            clearSession()
            throw e
        }
    }
}

nonisolated enum AuthProvider: String, CaseIterable, Sendable {
    case google
    case azure

    var label: String { self == .google ? "Continue with Google" : "Continue with Microsoft" }
    /// Microsoft (Entra ID) only returns an email address when asked for it.
    var scopes: String? { self == .azure ? "email" : nil }
}

/// Reads and writes the app's own settings (UserDefaults and AirportStore) as synced values.
struct SettingsBridge {
    static let keys: [SettingKey] = [.airport, .gloveMode, .keepAwake, .appearance, .windCautionKt, .windWarningKt]

    let store: AirportStore
    let defaults: UserDefaults

    func read() -> [SettingKey: SettingValue] {
        [
            .airport: .string(store.icao),
            .gloveMode: .bool(defaults.bool(forKey: "gloveMode")),
            .keepAwake: .bool(defaults.bool(forKey: "keepAwake")),
            .appearance: .string((Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .auto).rawValue.lowercased()),
            .windCautionKt: .int(store.thresholds.windCautionKt),
            .windWarningKt: .int(store.thresholds.windWarningKt),
        ]
    }

    func defaultValue(_ key: SettingKey) -> SettingValue? {
        switch key {
        case .airport: .string("VHHH")
        case .gloveMode, .keepAwake: .bool(false)
        case .appearance: .string("auto")
        case .windCautionKt: .int(RampThresholds.standard.windCautionKt)
        case .windWarningKt: .int(RampThresholds.standard.windWarningKt)
        default: nil
        }
    }

    /// Applies the synced values that differ from this device's. Keys the account does not
    /// have keep this device's value.
    func apply(_ synced: SyncedSettings) {
        let current = read()
        if let icao = synced[.airport]?.string, icao != store.icao { store.select(icao) }
        for key in [SettingKey.gloveMode, .keepAwake] {
            if let b = synced[key]?.bool, current[key] != .bool(b) { defaults.set(b, forKey: key.rawValue) }
        }
        if let a = synced[.appearance]?.string, current[.appearance] != .string(a),
           let mode = Appearance.allCases.first(where: { $0.rawValue.lowercased() == a }) {
            defaults.set(mode.rawValue, forKey: "appearance")
        }
        var t = store.thresholds
        if let c = synced[.windCautionKt]?.int { t.windCautionKt = c }
        if let w = synced[.windWarningKt]?.int { t.windWarningKt = max(w, t.windCautionKt) }
        if t != store.thresholds { store.thresholds = t }
    }
}
