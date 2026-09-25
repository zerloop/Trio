import Foundation
import HealthKit
import Testing

@testable import Trio

@Suite("HealthKitAnchorStore") struct HealthKitAnchorStoreTests {
    private func makeStore() -> HealthKitAnchorStore {
        let suite = "HealthKitAnchorStoreTests.\(UUID().uuidString)"
        return HealthKitAnchorStore(defaults: UserDefaults(suiteName: suite)!)
    }

    private func archived(_ anchor: HKQueryAnchor?) throws -> Data? {
        try anchor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    @Test("Unknown source has no anchor") func unknownSource() {
        #expect(makeStore().anchor(for: "com.teljane.instara") == nil)
    }

    @Test("A saved anchor round-trips") func roundTrip() throws {
        let store = makeStore()
        let anchor = HKQueryAnchor(fromValue: 42)
        store.save(anchor, for: "com.teljane.instara")
        #expect(try archived(store.anchor(for: "com.teljane.instara")) == archived(anchor))
    }

    @Test("Anchors are kept per source app") func anchorsAreKeptPerSource() throws {
        let store = makeStore()
        store.save(HKQueryAnchor(fromValue: 42), for: "com.teljane.instara")
        #expect(store.anchor(for: "com.apple.Health") == nil)
        store.save(HKQueryAnchor(fromValue: 7), for: "com.apple.Health")
        #expect(try archived(store.anchor(for: "com.teljane.instara")) == archived(HKQueryAnchor(fromValue: 42)))
    }

    @Test("Removing an anchor forgets it") func removingAnAnchorForgetsIt() {
        let store = makeStore()
        store.save(HKQueryAnchor(fromValue: 42), for: "com.teljane.instara")
        store.remove(for: "com.teljane.instara")
        #expect(store.anchor(for: "com.teljane.instara") == nil)

        // Removing an unknown source does not throw or crash.
        store.remove(for: "com.unknown.source")
    }
}
