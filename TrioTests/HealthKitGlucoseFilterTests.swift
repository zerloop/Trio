import Foundation
import HealthKit
import LoopKit
import Testing

@testable import Trio

@Suite("HealthKitGlucoseFilter") struct HealthKitGlucoseFilterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let instara = "com.teljane.instara"
    private let trio = "org.nightscout.trio"

    private func sample(
        _ mgdl: Double,
        minutesAgo: Double,
        source: String = "com.teljane.instara",
        userEntered: Bool = false
    ) -> HealthGlucoseSample {
        HealthGlucoseSample(
            uuid: UUID(),
            date: now.addingTimeInterval(-minutesAgo * 60),
            mgdl: mgdl,
            sourceBundleID: source,
            wasUserEntered: userEntered
        )
    }

    private func filter(selected: String? = "com.teljane.instara", acceptUserEntered: Bool = false) -> HealthKitGlucoseFilter {
        HealthKitGlucoseFilter(selectedSourceBundleID: selected, acceptUserEntered: acceptUserEntered, ownBundleID: trio)
    }

    @Test("Only the selected app's samples are kept") func selectedSourceOnly() {
        let result = filter().readings(
            from: [sample(110, minutesAgo: 1), sample(200, minutesAgo: 2, source: "com.other.meter")],
            previous: [],
            now: now
        )
        #expect(result.map(\.glucose) == [110])
    }

    @Test("No selected app means no readings") func noSelection() {
        #expect(filter(selected: nil).readings(from: [sample(110, minutesAgo: 1)], previous: [], now: now).isEmpty)
    }

    @Test("Trio's own samples are dropped even when Trio is selected") func ownSamplesDropped() {
        let result = filter(selected: trio).readings(from: [sample(110, minutesAgo: 1, source: trio)], previous: [], now: now)
        #expect(result.isEmpty)
    }

    @Test("Manually entered samples need the test switch") func userEntered() {
        let entered = [sample(110, minutesAgo: 1, userEntered: true)]
        #expect(filter().readings(from: entered, previous: [], now: now).isEmpty)
        #expect(filter(acceptUserEntered: true).readings(from: entered, previous: [], now: now).map(\.glucose) == [110])
    }

    @Test("Samples older than 24 h or over 5 min in the future are dropped") func dateBounds() {
        let result = filter().readings(
            from: [
                sample(101, minutesAgo: 24 * 60 + 1),
                sample(102, minutesAgo: 24 * 60 - 1),
                sample(103, minutesAgo: -4),
                sample(104, minutesAgo: -6)
            ],
            previous: [],
            now: now
        )
        #expect(result.map(\.glucose) == [102, 103])
    }

    @Test("Readings carry sgv, glucose, id, type and a rounded value") func readingShape() throws {
        let input = sample(110.6, minutesAgo: 1)
        let reading = try #require(filter().readings(from: [input], previous: [], now: now).first)
        #expect(reading.glucose == 111)
        #expect(reading.sgv == 111)
        #expect(reading.id == input.uuid.uuidString)
        #expect(reading.type == "sgv")
        #expect(reading.dateString == input.date)
        #expect(reading.date == Decimal(Int(input.date.timeIntervalSince1970 * 1000)))
    }

    @Test("Trend uses previously delivered readings") func trendFromPrevious() throws {
        let previous = [BloodGlucose(
            direction: nil,
            date: 0,
            dateString: now.addingTimeInterval(-6 * 60),
            glucose: 100
        )]
        let reading = try #require(filter().readings(from: [sample(115, minutesAgo: 1)], previous: previous, now: now).first)
        #expect(reading.direction == .doubleUp) // 15 mg/dL over 5 min
    }

    @Test("A backlog batch chains trend through its own readings") func batchReadingsChainTrend() {
        let result = filter().readings(
            from: [sample(100, minutesAgo: 15), sample(100, minutesAgo: 10), sample(110, minutesAgo: 5)],
            previous: [],
            now: now
        )
        // 0 then 10 mg/dL over 5 minutes: 0.0 → flat, 2.0 → singleUp
        #expect(result.map(\.direction) == [nil, .flat, .singleUp])
    }

    @Test("Unsorted samples come out sorted by date") func unsortedSamplesAreSorted() {
        let result = filter().readings(
            from: [sample(110, minutesAgo: 5), sample(100, minutesAgo: 15), sample(100, minutesAgo: 10)],
            previous: [],
            now: now
        )
        #expect(result.map(\.glucose) == [100, 100, 110])
        #expect(result.last?.direction == .singleUp)
    }

    @Test("A mmol/L quantity is converted to mg/dL") func mmolSampleIsConverted() {
        let converted = HealthGlucoseSample(
            uuid: UUID(),
            date: now,
            quantity: HKQuantity(unit: .millimolesPerLiter, doubleValue: 5.5),
            sourceBundleID: instara,
            metadata: nil
        )
        #expect(Int(converted.mgdl.rounded()) == 99)
    }

    @Test("The user-entered flag is read from metadata") func userEnteredMetadata() {
        let entered = HealthGlucoseSample(
            uuid: UUID(),
            date: now,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            sourceBundleID: instara,
            metadata: [HKMetadataKeyWasUserEntered: true]
        )
        #expect(entered.wasUserEntered)
    }
}
