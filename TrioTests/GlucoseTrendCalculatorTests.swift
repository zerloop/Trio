import Foundation
import Testing

@testable import Trio

@Suite("GlucoseTrendCalculator") struct GlucoseTrendCalculatorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Direction for a reading `delta` mg/dL above one taken 5 minutes earlier at 120 mg/dL.
    private func direction(delta: Int) -> BloodGlucose.Direction? {
        GlucoseTrendCalculator.direction(
            glucose: 120 + delta,
            at: now,
            previous: [(date: now.addingTimeInterval(-5 * 60), glucose: 120)]
        )
    }

    @Test("Rising thresholds") func rising() {
        #expect(direction(delta: 15) == .doubleUp) // 3.0 mg/dL/min
        #expect(direction(delta: 14) == .singleUp) // 2.8
        #expect(direction(delta: 10) == .singleUp) // 2.0
        #expect(direction(delta: 9) == .fortyFiveUp) // 1.8
        #expect(direction(delta: 5) == .fortyFiveUp) // 1.0
        #expect(direction(delta: 4) == .flat) // 0.8
    }

    @Test("Falling thresholds") func falling() {
        #expect(direction(delta: -4) == .flat) // -0.8
        #expect(direction(delta: -5) == .fortyFiveDown) // -1.0
        #expect(direction(delta: -9) == .fortyFiveDown) // -1.8
        #expect(direction(delta: -10) == .singleDown) // -2.0
        #expect(direction(delta: -14) == .singleDown) // -2.8
        #expect(direction(delta: -15) == .doubleDown) // -3.0
    }

    @Test("No earlier reading gives no arrow") func noPrevious() {
        #expect(GlucoseTrendCalculator.direction(glucose: 120, at: now, previous: []) == nil)
    }

    @Test("Readings outside the 4–15 minute window are ignored") func windowBounds() {
        let tooClose = [(date: now.addingTimeInterval(-3 * 60), glucose: 100)]
        let tooOld = [(date: now.addingTimeInterval(-16 * 60), glucose: 100)]
        #expect(GlucoseTrendCalculator.direction(glucose: 150, at: now, previous: tooClose) == nil)
        #expect(GlucoseTrendCalculator.direction(glucose: 150, at: now, previous: tooOld) == nil)
    }

    @Test("The most recent reading inside the window is the reference") func mostRecentReference() {
        let previous = [
            (date: now.addingTimeInterval(-10 * 60), glucose: 60),
            (date: now.addingTimeInterval(-5 * 60), glucose: 118)
        ]
        // Against the 5-minute reading the rate is 0.4 → flat; against the 10-minute one it would be 6.0.
        #expect(GlucoseTrendCalculator.direction(glucose: 120, at: now, previous: previous) == .flat)
    }
}
