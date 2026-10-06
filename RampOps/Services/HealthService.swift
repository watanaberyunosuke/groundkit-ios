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
    var soundAverageDb: Double?
    var soundMaxDb: Double?
    var waterMl: Double?
}

@Observable
final class HealthService {
    private(set) var stats = ShiftStats()
    private(set) var lastError: String?
    private(set) var hasRequestedAccess: Bool

    private let store: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil

    var isAvailable: Bool { store != nil }

    private static let water = HKQuantityType(.dietaryWater)
    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate),
        HKQuantityType(.environmentalAudioExposure),
        water,
    ]
    private static let requestedKey = "healthAccessRequested"

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
    }

    func refresh(since start: Date) async {
        guard let store, hasRequestedAccess else { return }
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
        let heart = await query(.heartRate, [.discreteAverage, .mostRecent])
        let sound = await query(.environmentalAudioExposure, [.discreteAverage, .discreteMax])
        let water = await query(.dietaryWater, .cumulativeSum)

        stats = ShiftStats(
            steps: steps?.sumQuantity()?.doubleValue(for: .count()),
            distanceKm: distance?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)),
            activeKcal: energy?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            heartRateLatest: heart?.mostRecentQuantity()?.doubleValue(for: bpm),
            heartRateAverage: heart?.averageQuantity()?.doubleValue(for: bpm),
            soundAverageDb: sound?.averageQuantity()?.doubleValue(for: dB),
            soundMaxDb: sound?.maximumQuantity()?.doubleValue(for: dB),
            waterMl: water?.sumQuantity()?.doubleValue(for: .literUnit(with: .milli)))
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

/// Plain guidance from the weather and Health data. Not medical advice.
enum ShiftAdvice {
    /// Water to drink per hour on the ramp: about 250 ml every 20 minutes in heat stress
    /// (common occupational guidance), less otherwise.
    static func waterPerHourMl(feelsLikeC: Double?) -> Double {
        guard let feelsLikeC else { return 300 }
        if feelsLikeC >= 32 { return 750 }
        if feelsLikeC >= 27 { return 500 }
        return 300
    }

    /// Sustained exposure at or above 85 dB(A) calls for hearing protection.
    static let hearingProtectionDb = 85.0
}
