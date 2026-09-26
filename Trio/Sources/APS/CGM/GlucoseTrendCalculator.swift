import Foundation

/// Derives a trend arrow for sources that deliver bare glucose values, such as Apple Health.
enum GlucoseTrendCalculator {
    /// Earlier readings closer than this are too noisy to derive a rate from.
    static let minimumSpan: TimeInterval = 4 * 60
    /// Earlier readings further back than this no longer describe the current trend.
    static let maximumSpan: TimeInterval = 15 * 60

    /// - Parameters:
    ///   - glucose: the reading, in mg/dL, the arrow is for.
    ///   - date: when that reading was taken.
    ///   - previous: earlier readings in any order; only the most recent one 4–15 minutes older is used.
    /// - Returns: the arrow, or nil when no earlier reading falls inside the window.
    static func direction(
        glucose: Int,
        at date: Date,
        previous: [(date: Date, glucose: Int)]
    ) -> BloodGlucose.Direction? {
        let reference = previous
            .filter {
                let span = date.timeIntervalSince($0.date)
                return span >= minimumSpan && span <= maximumSpan
            }
            .max { $0.date < $1.date }
        guard let reference else { return nil }

        let rate = Double(glucose - reference.glucose) / (date.timeIntervalSince(reference.date) / 60)
        if rate >= 3 { return .doubleUp }
        if rate >= 2 { return .singleUp }
        if rate >= 1 { return .fortyFiveUp }
        if rate > -1 { return .flat }
        if rate > -2 { return .fortyFiveDown }
        if rate > -3 { return .singleDown }
        return .doubleDown
    }
}
