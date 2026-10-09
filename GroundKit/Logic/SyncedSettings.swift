import Foundation

/// The settings synced through a GroundKit account, shared with the Android app and the web
/// dashboard (contract: the aviation repo's docs/accounts.md section 3).
///
/// The app keeps the values, when each key last changed (its stamp) and the keys changed
/// since the last successful sync (pending). A sync sends the pending keys to the
/// `merge_settings` function, which keeps the newer stamp per key, and adopts what it returns.
nonisolated enum SettingValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var int: Int? { if case .int(let i) = self { i } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
}

nonisolated enum SettingKey: String, CaseIterable, Sendable {
    case airport // home airport, ICAO
    case gloveMode
    case keepAwake
    case appearance // auto | sunset | light | dark
    case windCautionKt
    case windWarningKt
    case dashboardTheme
    case dashboardHomeTimeZone
    case dashboardLayout

    func isValid(_ v: SettingValue) -> Bool {
        switch self {
        case .airport: v.string.map { $0.range(of: #"^[A-Z0-9]{3,4}$"#, options: .regularExpression) != nil } ?? false
        case .gloveMode, .keepAwake: v.bool != nil
        case .appearance: ["auto", "sunset", "light", "dark"].contains(v.string ?? "")
        case .windCautionKt, .windWarningKt: v.int.map { (5...100).contains($0) } ?? false
        case .dashboardTheme: ["auto", "light", "dark"].contains(v.string ?? "")
        case .dashboardHomeTimeZone: (v.string?.count ?? 65) <= 64
        case .dashboardLayout: (v.string?.count ?? 1001) <= 1000
        }
    }
}

nonisolated struct SyncedSettings: Codable, Hashable, Sendable {
    var values: [String: SettingValue] = [:]
    var stamps: [String: String] = [:]
    var pending: [String] = []

    subscript(key: SettingKey) -> SettingValue? { values[key.rawValue] }

    /// Known keys with valid values. Unknown keys (from a newer client) are left out here
    /// but never deleted on the server, since only pending keys are sent.
    static func clean(_ raw: [String: SettingValue]) -> [String: SettingValue] {
        raw.filter { k, v in SettingKey(rawValue: k)?.isValid(v) ?? false }
    }

    /// A change made on this device: the new value (nil removes it), stamped `now`.
    mutating func change(_ key: SettingKey, to value: SettingValue?, now: Date = .now) {
        values[key.rawValue] = value
        stamps[key.rawValue] = Self.stamp(now)
        if !pending.contains(key.rawValue) { pending.append(key.rawValue) }
    }

    /// The arguments for `merge_settings`: pending keys, null for removed ones.
    var patch: MergeRequest {
        var patch: [String: SettingValue?] = [:]
        var stamps: [String: String] = [:]
        for k in pending {
            patch[k] = .some(values[k])
            if let s = self.stamps[k] { stamps[k] = s }
        }
        return MergeRequest(patch: patch, patchStamps: stamps)
    }

    /// Adopts the server's merged settings. Keys changed again while the request was in
    /// flight (their stamp differs from what was sent) stay local and pending.
    func adopting(_ server: MergeResponse, sent: [String: String]) -> SyncedSettings {
        var next = SyncedSettings(values: Self.clean(server.settings),
                                  stamps: server.stamps.filter { SettingKey(rawValue: $0.key) != nil },
                                  pending: pending.filter { stamps[$0] != sent[$0] })
        for k in next.pending {
            next.values[k] = values[k]
            next.stamps[k] = stamps[k]
        }
        return next
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) // 2026-10-09T10:00:00.123Z
    }
}

nonisolated struct MergeRequest: Encodable, Sendable {
    var patch: [String: SettingValue?]
    var patchStamps: [String: String]

    enum CodingKeys: String, CodingKey {
        case patch
        case patchStamps = "patch_stamps"
    }

    // Removed keys must go as JSON null, which the synthesised encoder would drop.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var p = c.nestedContainer(keyedBy: AnyKey.self, forKey: .patch)
        for (k, v) in patch {
            if let v { try p.encode(v, forKey: AnyKey(k)) } else { try p.encodeNil(forKey: AnyKey(k)) }
        }
        try c.encode(patchStamps, forKey: .patchStamps)
    }
}

nonisolated struct MergeResponse: Decodable, Sendable {
    var settings: [String: SettingValue]
    var stamps: [String: String]

    init(settings: [String: SettingValue], stamps: [String: String]) {
        self.settings = settings
        self.stamps = stamps
    }

    // A value of an unexpected shape (an array, an object) from a newer client is skipped
    // rather than failing the whole sync.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var settings: [String: SettingValue] = [:]
        if let s = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("settings")) {
            for k in s.allKeys { if let v = try? s.decode(SettingValue.self, forKey: k) { settings[k.stringValue] = v } }
        }
        self.settings = settings
        stamps = (try? c.decode([String: String].self, forKey: AnyKey("stamps"))) ?? [:]
    }
}

nonisolated struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
