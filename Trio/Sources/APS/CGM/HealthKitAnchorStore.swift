import Foundation
import HealthKit

/// Remembers, per source app, how far Trio has read Apple Health's blood glucose.
///
/// Keyed by source so that picking another app starts from scratch and rescans the last 24 hours.
struct HealthKitAnchorStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func anchor(for sourceBundleID: String) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: key(for: sourceBundleID)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func save(_ anchor: HKQueryAnchor, for sourceBundleID: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: key(for: sourceBundleID))
    }

    private func key(for sourceBundleID: String) -> String {
        "AppleHealthCGM.anchor.\(sourceBundleID)"
    }
}
