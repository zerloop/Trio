import Foundation
import HealthKit
import LoopKit

/// A blood glucose sample as read from Apple Health, reduced to what Trio decides on.
struct HealthGlucoseSample: Equatable {
    let uuid: UUID
    let date: Date
    let mgdl: Double
    let sourceBundleID: String
    let wasUserEntered: Bool
}

extension HealthGlucoseSample {
    init(uuid: UUID, date: Date, quantity: HKQuantity, sourceBundleID: String, metadata: [String: Any]?) {
        self.init(
            uuid: uuid,
            date: date,
            mgdl: quantity.doubleValue(for: .milligramsPerDeciliter),
            sourceBundleID: sourceBundleID,
            wasUserEntered: metadata?[HKMetadataKeyWasUserEntered] as? Bool ?? false
        )
    }

    init(_ sample: HKQuantitySample) {
        self.init(
            uuid: sample.uuid,
            date: sample.startDate,
            quantity: sample.quantity,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier,
            metadata: sample.metadata
        )
    }
}

/// Decides which Apple Health samples count as CGM readings and turns them into `BloodGlucose`.
///
/// Health also holds fingersticks, meter uploads and Trio's own copies; letting those into the algorithm as CGM
/// readings would dose on the wrong data, so only the app the user picked is trusted.
struct HealthKitGlucoseFilter {
    static let maximumAge: TimeInterval = 24 * 60 * 60
    static let maximumFutureSkew: TimeInterval = 5 * 60

    let selectedSourceBundleID: String?
    let acceptUserEntered: Bool
    let ownBundleID: String

    /// - Parameter previous: readings already handed to Trio; used only to give the first new reading an arrow.
    func readings(from samples: [HealthGlucoseSample], previous: [BloodGlucose], now: Date) -> [BloodGlucose] {
        guard let selectedSourceBundleID else { return [] }
        let oldest = now.addingTimeInterval(-Self.maximumAge)
        let newest = now.addingTimeInterval(Self.maximumFutureSkew)

        let accepted = samples
            .filter { $0.sourceBundleID == selectedSourceBundleID && $0.sourceBundleID != ownBundleID }
            .filter { acceptUserEntered || !$0.wasUserEntered }
            .filter { $0.date >= oldest && $0.date <= newest }
            .sorted { $0.date < $1.date }

        var history = previous.compactMap { reading in reading.glucose.map { (date: reading.dateString, glucose: $0) } }
        return accepted.map { sample in
            let glucose = Int(sample.mgdl.rounded())
            let direction = GlucoseTrendCalculator.direction(glucose: glucose, at: sample.date, previous: history)
            history.append((date: sample.date, glucose: glucose))
            return BloodGlucose(
                id: sample.uuid.uuidString,
                sgv: glucose,
                direction: direction,
                date: Decimal(Int(sample.date.timeIntervalSince1970 * 1000)),
                dateString: sample.date,
                unfiltered: Decimal(glucose),
                glucose: glucose,
                type: "sgv"
            )
        }
    }
}
