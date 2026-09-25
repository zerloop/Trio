import Combine
import Foundation
import HealthKit
import LoopKit
import LoopKitUI

/// Reads blood glucose that another app, such as Instara for the Perlanova sensor, writes to Apple Health.
///
/// HealthKit cannot be read while the iPhone is locked, so readings arrive in a burst after unlock; the anchor
/// makes sure none are skipped. New readings are pushed as soon as Health reports them, and the 1-minute timer
/// polls as a fallback; central dedup in `FetchGlucoseManager` absorbs any overlap.
final class HealthKitGlucoseSource: GlucoseSource {
    struct Settings {
        let sourceBundleID: String?
        let acceptUserEntered: Bool
    }

    var glucoseManager: FetchGlucoseManager?
    var cgmManager: CGMManagerUI?
    let cgmDisplayState = CurrentValueSubject<CgmDisplayState?, Never>(nil)
    let cgmProgressHighlight = CurrentValueSubject<LoopKit.DeviceLifecycleProgress?, Never>(nil)

    private let healthStore: HKHealthStore
    private let anchorStore: HealthKitAnchorStore
    private let settings: () -> Settings
    private let queue = DispatchQueue(label: "HealthKitGlucoseSource.queue")
    private var observerQuery: HKObserverQuery?
    /// Readings from the last few minutes, so the next reading can get a trend arrow.
    private var recent: [BloodGlucose] = []

    init(
        healthStore: HKHealthStore,
        anchorStore: HealthKitAnchorStore = HealthKitAnchorStore(),
        settings: @escaping () -> Settings,
        glucoseManager: FetchGlucoseManager?
    ) {
        self.healthStore = healthStore
        self.anchorStore = anchorStore
        self.settings = settings
        self.glucoseManager = glucoseManager
    }

    func start() {
        guard observerQuery == nil, let type = AppleHealthConfig.healthBGObject else { return }
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
            guard let self else {
                completion()
                return
            }
            if let error {
                warning(.service, "Apple Health glucose observer failed", error: error)
                completion()
                return
            }
            self.readNewSamples { readings in
                if readings.isNotEmpty {
                    self.glucoseManager?.newGlucoseFromCgmManager(newGlucose: readings)
                }
                completion()
            }
        }
        observerQuery = query
        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, error in
            if let error {
                warning(.service, "Unable to enable Apple Health background delivery for glucose", error: error)
            }
        }
    }

    func stop() {
        if let observerQuery {
            healthStore.stop(observerQuery)
        }
        observerQuery = nil
        guard let type = AppleHealthConfig.healthBGObject else { return }
        // Only glucose: disabling everything would also cut delivery other Trio features may register.
        healthStore.disableBackgroundDelivery(for: type) { _, _ in }
    }

    func fetch(_: DispatchTimer?) -> AnyPublisher<[BloodGlucose], Never> {
        Future { [weak self] promise in
            guard let self else {
                promise(.success([]))
                return
            }
            self.readNewSamples { promise(.success($0)) }
        }
        .eraseToAnyPublisher()
    }

    func fetchIfNeeded() -> AnyPublisher<[BloodGlucose], Never> {
        fetch(nil)
    }

    func sourceInfo() -> [String: Any]? {
        [GlucoseSourceKey.description.rawValue: "Apple Health: \(settings().sourceBundleID ?? "-")"]
    }

    private func readNewSamples(_ completion: @escaping ([BloodGlucose]) -> Void) {
        let current = settings()
        guard let sourceBundleID = current.sourceBundleID, let type = AppleHealthConfig.healthBGObject else {
            completion([])
            return
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-HealthKitGlucoseFilter.maximumAge),
            end: nil
        )
        let query = HKAnchoredObjectQuery(
            type: type,
            predicate: predicate,
            anchor: anchorStore.anchor(for: sourceBundleID),
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, added, _, newAnchor, error in
            guard let self else {
                completion([])
                return
            }
            self.queue.async {
                if let error {
                    // Expected while the iPhone is locked (errorDatabaseInaccessible). The anchor is left as it
                    // was, so the backlog is read after unlock.
                    debug(.deviceManager, "Apple Health glucose query failed: \(error.localizedDescription)")
                    completion([])
                    return
                }

                let samples = (added ?? []).compactMap { $0 as? HKQuantitySample }.map(HealthGlucoseSample.init)
                let filter = HealthKitGlucoseFilter(
                    selectedSourceBundleID: sourceBundleID,
                    acceptUserEntered: current.acceptUserEntered,
                    ownBundleID: Bundle.main.bundleIdentifier ?? ""
                )
                let readings = filter.readings(from: samples, previous: self.recent, now: Date())
                if let newAnchor {
                    self.anchorStore.save(newAnchor, for: sourceBundleID)
                }
                self.keepRecent(readings)
                completion(readings)
            }
        }
        healthStore.execute(query)
    }

    /// Keeps only what the trend window can still use, measured from the newest reading so a backlog read after
    /// unlock still chains correctly.
    private func keepRecent(_ readings: [BloodGlucose]) {
        let all = recent + readings
        guard let newest = all.map(\.dateString).max() else { return }
        recent = all.filter { newest.timeIntervalSince($0.dateString) <= GlucoseTrendCalculator.maximumSpan }
    }
}

extension HealthKitGlucoseSource {
    static func requestReadAuthorization(_ store: HKHealthStore) async throws {
        guard let type = AppleHealthConfig.healthBGObject else { return }
        try await store.requestAuthorization(toShare: [], read: [type])
    }

    /// Apps that have written blood glucose to Apple Health, Trio itself excluded, sorted by name.
    static func glucoseSources(_ store: HKHealthStore) async -> [HKSource] {
        guard let type = AppleHealthConfig.healthBGObject else { return [] }
        return await withCheckedContinuation { continuation in
            let query = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, _ in
                let own = Bundle.main.bundleIdentifier
                let result = (sources ?? [])
                    .filter { $0.bundleIdentifier != own }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }
}
