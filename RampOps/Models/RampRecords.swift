import Foundation
import SwiftData

// Records the crew keeps: turnarounds, shifts and handover notes. SwiftData syncs them to
// the user's iCloud private database (CloudKit) on every device signed in to the same
// Apple Account. CloudKit needs every attribute to have a default (or be optional), no
// unique constraints, and optional relationships with inverses.

@Model
final class Turnaround {
    var airportIcao: String = ""
    var callsign: String = ""
    var flightIata: String?
    var airline: String?
    /// Inbound origin and outbound destination, IATA where known.
    var origin: String?
    var destination: String?
    var stand: String = ""
    var registration: String = ""
    var createdAt: Date = Date.now
    /// Target off-block time.
    var targetOffBlock: Date?
    var hasDangerousGoods: Bool = false
    var bagsOffloaded: Int = 0
    var bagsLoaded: Int = 0
    var uldsOffloaded: Int = 0
    var uldsLoaded: Int = 0
    var notes: String = ""
    var closedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \TurnaroundEvent.turnaround)
    var events: [TurnaroundEvent]? = []

    init(airportIcao: String, callsign: String, flightIata: String? = nil, airline: String? = nil,
         origin: String? = nil, destination: String? = nil, stand: String = "",
         registration: String = "", targetOffBlock: Date? = nil) {
        self.airportIcao = airportIcao
        self.callsign = callsign
        self.flightIata = flightIata
        self.airline = airline
        self.origin = origin
        self.destination = destination
        self.stand = stand
        self.registration = registration
        self.targetOffBlock = targetOffBlock
    }

    var label: String { flightIata ?? (callsign.isEmpty ? "Turnaround" : callsign) }
    var isClosed: Bool { closedAt != nil }

    var steps: [TurnaroundStep] { TurnaroundStep.allCases.filter { !$0.dangerousGoodsOnly || hasDangerousGoods } }

    /// When each step was done (the latest event per step).
    var completed: [TurnaroundStep: Date] {
        var out: [TurnaroundStep: Date] = [:]
        for e in events ?? [] {
            guard let step = TurnaroundStep(rawValue: e.step) else { continue }
            out[step] = max(out[step] ?? .distantPast, e.at)
        }
        return out
    }

    var nextStep: TurnaroundStep? {
        let done = completed
        return steps.first { done[$0] == nil }
    }

    var progress: Double {
        let done = completed
        return Double(steps.filter { done[$0] != nil }.count) / Double(max(steps.count, 1))
    }

    var onBlocksAt: Date? { completed[.chocksOn] }
}

@Model
final class TurnaroundEvent {
    /// A `TurnaroundStep` raw value. Stored as text so new steps sync to older app versions.
    var step: String = ""
    var at: Date = Date.now
    var turnaround: Turnaround?

    init(step: TurnaroundStep, at: Date = .now) {
        self.step = step.rawValue
        self.at = at
    }
}

@Model
final class Shift {
    var airportIcao: String = ""
    var startedAt: Date = Date.now
    var endedAt: Date?
    var waterMl: Double = 0

    init(airportIcao: String, startedAt: Date = .now) {
        self.airportIcao = airportIcao
        self.startedAt = startedAt
    }

    var isActive: Bool { endedAt == nil }
    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }
}

@Model
final class HandoverNote {
    var airportIcao: String = ""
    var createdAt: Date = Date.now
    var text: String = ""
    var isImportant: Bool = false
    var resolvedAt: Date?

    init(airportIcao: String, text: String, isImportant: Bool = false) {
        self.airportIcao = airportIcao
        self.text = text
        self.isImportant = isImportant
    }
}

/// A ground-handling turnaround, in the usual order. Ramp, baggage and cargo steps.
nonisolated enum TurnaroundStep: String, CaseIterable, Codable, Sendable, Identifiable {
    case chocksOn, conesPlaced, gpuConnected, holdsOpen
    case bagsOffloaded, cargoOffloaded
    case fuelled, catered, cleaned, watered
    case bagsLoaded, cargoLoaded, notoc, loadsheet
    case holdsClosed, gpuRemoved, chocksOff, pushback

    enum Phase: String, CaseIterable, Sendable {
        case arrival = "Arrival"
        case offload = "Offload"
        case servicing = "Servicing"
        case load = "Load"
        case departure = "Departure"
    }

    var id: String { rawValue }

    var phase: Phase {
        switch self {
        case .chocksOn, .conesPlaced, .gpuConnected, .holdsOpen: .arrival
        case .bagsOffloaded, .cargoOffloaded: .offload
        case .fuelled, .catered, .cleaned, .watered: .servicing
        case .bagsLoaded, .cargoLoaded, .notoc, .loadsheet: .load
        case .holdsClosed, .gpuRemoved, .chocksOff, .pushback: .departure
        }
    }

    var title: String {
        switch self {
        case .chocksOn: "Chocks on"
        case .conesPlaced: "Cones placed"
        case .gpuConnected: "GPU on"
        case .holdsOpen: "Holds open"
        case .bagsOffloaded: "Bags off"
        case .cargoOffloaded: "Cargo / ULDs off"
        case .fuelled: "Fuelling done"
        case .catered: "Catering done"
        case .cleaned: "Cleaning done"
        case .watered: "Water / toilets"
        case .bagsLoaded: "Bags loaded"
        case .cargoLoaded: "Cargo / ULDs loaded"
        case .notoc: "NOTOC to captain"
        case .loadsheet: "Loadsheet"
        case .holdsClosed: "Holds closed"
        case .gpuRemoved: "GPU off"
        case .chocksOff: "Chocks off"
        case .pushback: "Pushback"
        }
    }

    var symbol: String {
        switch self {
        case .chocksOn, .chocksOff: "stop.circle"
        case .conesPlaced: "cone"
        case .gpuConnected, .gpuRemoved: "powerplug"
        case .holdsOpen, .holdsClosed: "door.left.hand.open"
        case .bagsOffloaded, .bagsLoaded: "suitcase.rolling"
        case .cargoOffloaded, .cargoLoaded: "shippingbox"
        case .fuelled: "fuelpump"
        case .catered: "fork.knife"
        case .cleaned: "sparkles"
        case .watered: "drop"
        case .notoc: "exclamationmark.triangle"
        case .loadsheet: "doc.text"
        case .pushback: "arrow.uturn.backward"
        }
    }

    /// The NOTOC (notification to captain) is only needed with dangerous goods on board.
    var dangerousGoodsOnly: Bool { self == .notoc }
}

enum Persistence {
    static let schema = Schema([Turnaround.self, TurnaroundEvent.self, Shift.self, HandoverNote.self])

    /// CloudKit sync when the app is signed with the iCloud container in its entitlements;
    /// a store on this device otherwise (unsigned simulator builds, no iCloud account).
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        if inMemory {
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic))
        } catch {
            print("CloudKit store unavailable, keeping records on this device: \(error)")
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        }
    }

    /// Whether an iCloud account is signed in, without touching CKContainer (which traps
    /// when the app lacks the iCloud entitlement).
    static var iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }
}
