import Foundation
import HealthKit
import Observation

/// What Health knows about the current shift. Every value is nil when Health has no data
/// (sound levels need an Apple Watch) or the user declined that type.
struct ShiftStats: Equatable {
    var steps: Double?
    var distanceKm: Double?
    var activeKcal: Double?
    var heartRateLatest: Double?
    var heartRateAverage: Double?
    var heartRateMax: Double?
    var soundAverageDb: Double?
    var soundMaxDb: Double?
    var waterMl: Double?
}

@Observable
final class HealthService {
    private(set) var stats = ShiftStats()
    /// Sleep in the 48 h before the shift (or now, off shift); nil before Health is connected.
    private(set) var sleep: [SleepSpan]?
    /// Heart rate over the last few minutes, for the heat-strain check.
    private(set) var recentHeartRate: [HeatStrain.Sample] = []
    private(set) var lastError: String?
    private(set) var hasRequestedAccess: Bool
    /// Health has types it hasn't asked about yet, such as sleep after an update added it.
    private(set) var canAskForMore = false

    private let store: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil

    var isAvailable: Bool { store != nil }

    private static let water = HKQuantityType(.dietaryWater)
    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate),
        HKQuantityType(.environmentalAudioExposure),
        HKCategoryType(.sleepAnalysis),
        water,
    ]
    private static let requestedKey = "healthAccessRequested"
    /// Longest sleep looked back for, so one that started before the window counts.
    private static let sleepLookback: TimeInterval = 16 * 3600
    /// Heart rate kept for the heat-strain check: its 5 minutes plus a margin.
    private static let heartWindow: TimeInterval = 10 * 60

    init() {
        hasRequestedAccess = UserDefaults.standard.bool(forKey: Self.requestedKey)
    }

    /// Shows the Health permission sheet once; Health never says which types were refused.
    func requestAccess() async {
        guard let store else { return }
        do {
            try await store.requestAuthorization(toShare: [Self.water], read: Self.readTypes)
            hasRequestedAccess = true
            UserDefaults.standard.set(true, forKey: Self.requestedKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await checkForNewTypes()
    }

    /// Whether the permission sheet has types to show; Health never says which reads were refused.
    func checkForNewTypes() async {
        guard let store, hasRequestedAccess else { return }
        let status = try? await store.statusForAuthorizationRequest(toShare: [Self.water], read: Self.readTypes)
        canAskForMore = status == .shouldRequest
    }

    /// The shift's totals and recent heart rate while on shift (`start` set), and sleep
    /// before the shift, or before now as a check before starting one.
    func refresh(since start: Date?) async {
        guard let store, hasRequestedAccess else { return }
        let now = Date.now
        sleep = await readSleep(store, from: (start ?? now) - 2 * 86_400, to: now)
        guard let start else {
            stats = ShiftStats()
            recentHeartRate = []
            return
        }
        recentHeartRate = await readHeartRate(store, from: now - Self.heartWindow)
        let window = HKQuery.predicateForSamples(withStart: start, end: nil)
        func query(_ id: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions) async -> HKStatistics? {
            let descriptor = HKStatisticsQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(id), predicate: window), options: options)
            return try? await descriptor.result(for: store)
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let dB = HKUnit.decibelAWeightedSoundPressureLevel()

        let steps = await query(.stepCount, .cumulativeSum)
        let distance = await query(.distanceWalkingRunning, .cumulativeSum)
        let energy = await query(.activeEnergyBurned, .cumulativeSum)
        let heart = await query(.heartRate, [.discreteAverage, .discreteMax, .mostRecent])
        let sound = await query(.environmentalAudioExposure, [.discreteAverage, .discreteMax])
        let water = await query(.dietaryWater, .cumulativeSum)

        stats = ShiftStats(
            steps: steps?.sumQuantity()?.doubleValue(for: .count()),
            distanceKm: distance?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)),
            activeKcal: energy?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            heartRateLatest: heart?.mostRecentQuantity()?.doubleValue(for: bpm),
            heartRateAverage: heart?.averageQuantity()?.doubleValue(for: bpm),
            heartRateMax: heart?.maximumQuantity()?.doubleValue(for: bpm),
            soundAverageDb: sound?.averageQuantity()?.doubleValue(for: dB),
            soundMaxDb: sound?.maximumQuantity()?.doubleValue(for: dB),
            waterMl: water?.sumQuantity()?.doubleValue(for: .literUnit(with: .milli)))
    }

    /// Time asleep overlapping [from, to]: the asleep stages only, not time in bed or awake.
    /// Nil when Health couldn't be read, so "no data" and "no sleep" differ.
    private func readSleep(_ store: HKHealthStore, from: Date, to: Date) async -> [SleepSpan]? {
        // A sleep that began before `from` still counts for the part after it.
        let window = HKQuery.predicateForSamples(withStart: from - Self.sleepLookback, end: to)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: window)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues
        return samples
            .filter { HKCategoryValueSleepAnalysis(rawValue: $0.value).map(asleep.contains) == true }
            .map { SleepSpan(start: $0.startDate, end: $0.endDate) }
            .filter { $0.end > from }
    }

    private func readHeartRate(_ store: HKHealthStore, from: Date) async -> [HeatStrain.Sample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: HKQuery.predicateForSamples(withStart: from, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let samples = (try? await descriptor.result(for: store)) ?? []
        return samples.map { HeatStrain.Sample(at: $0.startDate, bpm: $0.quantity.doubleValue(for: bpm)) }
    }

    /// Saves a drink to Health. Returns false when Health is unavailable or refused it.
    @discardableResult
    func logWater(ml: Double, at date: Date = .now) async -> Bool {
        guard let store else { return false }
        if !hasRequestedAccess { await requestAccess() }
        let sample = HKQuantitySample(type: Self.water,
                                      quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: ml),
                                      start: date, end: date)
        do {
            try await store.save(sample)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
