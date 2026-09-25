# Apple Health as CGM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in "Apple Health" glucose source to Trio so readings that the Instara app (Perlanova / Teljane Instara-1 sensor) writes to Apple Health drive Trio like any other CGM.

**Architecture:** A new `CGMType.appleHealth` case, backed by `HealthKitGlucoseSource` (an `HKObserverQuery` with background delivery, plus an `HKAnchoredObjectQuery` from a persisted anchor). Two pure units, `HealthKitGlucoseFilter` and `GlucoseTrendCalculator`, decide which samples count and derive trend arrows. Everything downstream (dedup, calibration, smoothing, storage, loop heartbeat) stays in `FetchGlucoseManager` and `GlucoseStorage`, unchanged apart from not writing these readings back to Health.

**Tech Stack:** Swift 5, SwiftUI, HealthKit, Combine, CoreData, Swift Testing (`@Suite`/`@Test`/`#expect`), Swinject.

**Spec:** `docs/superpowers/specs/2026-09-25-apple-health-cgm-design.md`

## Global Constraints

- Branch: `feature/apple-health-cgm`. Never commit to `i18n_tr` or `dev`.
- Only glucose from the source app the user selected is accepted; Trio's own samples are always dropped; `HKMetadataKeyWasUserEntered` samples are dropped unless "accept manually entered values (testing only)" is on.
- Samples older than 24 h or more than 5 min in the future are dropped.
- Trend thresholds (mg/dL/min, against the most recent earlier reading 4–15 min older): `≥ 3` doubleUp; `[2, 3)` singleUp; `[1, 2)` fortyFiveUp; `(-1, 1)` flat; `(-2, -1]` fortyFiveDown; `(-3, -2]` singleDown; `≤ -3` doubleDown; no reading in the window → `nil`.
- Never call `HKHealthStore.disableAllBackgroundDelivery`; disable blood glucose only.
- Every user-facing string uses `String(localized:comment:)` or a SwiftUI `Text` literal, and gets a Turkish translation in `Trio/Sources/Localizations/Main/Localizable.xcstrings` via `docs/superpowers/plans/tools/add_xcstrings.py`.
- New `.swift` files must be added to `Trio.xcodeproj` with `docs/superpowers/plans/tools/add_to_xcodeproj.py` (the project uses explicit file references, not synchronized folders), next to the sibling named in each task.
- Commit messages end with the line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Test command (referred to below as `$TEST`):
  `xcodebuild test -workspace Trio.xcworkspace -scheme "Trio Tests" -destination 'platform=iOS Simulator,name=iPhone 15 Pro' CODE_SIGNING_ALLOWED=NO`
  followed by `-only-testing:TrioTests/<SuiteStruct>` for a single suite. Pipe through `| tail -40`. If the first run fails on signing or a missing simulator, report it rather than editing project settings.

## Review Focus

1. **Backlog after unlock**: a burst of many readings arrives at once. The expected behavior is that each one gets an arrow computed from its predecessor within the batch, not only from before the batch. Pinned in Task 2 (`batchReadingsChainTrend`).
2. **Unsorted HealthKit results**: anchored queries do not guarantee date order. Readings must still come out sorted and get correct arrows. Pinned in Task 2 (`unsortedSamplesAreSorted`).
3. **Source switch**: selecting a different source app must not reuse the old app's anchor, otherwise the new app's last 24 h are never read. Pinned in Task 3 (`anchorsAreKeptPerSource`).
4. **mmol/L writers**: some CGM apps write mmol/L to Health. Values must be converted, not read as mg/dL. Pinned in Task 2 (`mmolSampleIsConverted`).
5. **Write-back loop**: readings from this source must not be uploaded back to Health, while other sources keep uploading. Pinned in Task 5 (both tests).

## Deliberate deviations from the spec

- Trend history lives in memory in `HealthKitGlucoseSource` (the last 15 minutes of readings it delivered), not in a query against stored glucose. Effect: the first reading after an app launch has no arrow; the next one does. This keeps the source independent of `GlucoseStorage`.
- The settings screen shows the time and age of the newest stored reading, not its value; the value is already on the home screen.

---

### Task 1: GlucoseTrendCalculator

**Files:**
- Create: `Trio/Sources/APS/CGM/GlucoseTrendCalculator.swift`
- Create: `TrioTests/GlucoseTrendCalculatorTests.swift`
- Modify: `Trio.xcodeproj/project.pbxproj` (via helper)

**Interfaces:**
- Consumes: `BloodGlucose.Direction` (`Trio/Sources/Models/BloodGlucose.swift:4`).
- Produces: `enum GlucoseTrendCalculator` with `static let minimumSpan: TimeInterval` (240), `static let maximumSpan: TimeInterval` (900), and `static func direction(glucose: Int, at date: Date, previous: [(date: Date, glucose: Int)]) -> BloodGlucose.Direction?`.

- [ ] **Step 1: Register the two new files in the Xcode project**

```bash
touch Trio/Sources/APS/CGM/GlucoseTrendCalculator.swift TrioTests/GlucoseTrendCalculatorTests.swift
python3 docs/superpowers/plans/tools/add_to_xcodeproj.py Trio.xcodeproj/project.pbxproj AppGroupSource.swift GlucoseTrendCalculator.swift
python3 docs/superpowers/plans/tools/add_to_xcodeproj.py Trio.xcodeproj/project.pbxproj GlucoseSmoothingTests.swift GlucoseTrendCalculatorTests.swift
```
Expected: two `added ... (1 target(s))` lines.

- [ ] **Step 2: Write the failing tests** in `TrioTests/GlucoseTrendCalculatorTests.swift`

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `$TEST -only-testing:TrioTests/GlucoseTrendCalculatorTests | tail -40`
Expected: build failure, `cannot find 'GlucoseTrendCalculator' in scope`.

- [ ] **Step 4: Implement** `Trio/Sources/APS/CGM/GlucoseTrendCalculator.swift`

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `$TEST -only-testing:TrioTests/GlucoseTrendCalculatorTests | tail -40`
Expected: `** TEST SUCCEEDED **`, 5 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Trio/Sources/APS/CGM/GlucoseTrendCalculator.swift TrioTests/GlucoseTrendCalculatorTests.swift Trio.xcodeproj/project.pbxproj
git commit -m "Derive trend arrows for glucose sources that send none

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: HealthKitGlucoseFilter

**Files:**
- Create: `Trio/Sources/APS/CGM/HealthKitGlucoseFilter.swift`
- Create: `TrioTests/HealthKitGlucoseFilterTests.swift`
- Modify: `Trio.xcodeproj/project.pbxproj` (via helper)

**Interfaces:**
- Consumes: `GlucoseTrendCalculator.direction(glucose:at:previous:)` from Task 1; `BloodGlucose.init(id:sgv:direction:date:dateString:unfiltered:glucose:type:)` (`BloodGlucose.swift:123`, all other parameters defaulted).
- Produces:
  - `struct HealthGlucoseSample: Equatable { let uuid: UUID; let date: Date; let mgdl: Double; let sourceBundleID: String; let wasUserEntered: Bool }`
  - `init(uuid: UUID, date: Date, quantity: HKQuantity, sourceBundleID: String, metadata: [String: Any]?)` and `init(_ sample: HKQuantitySample)` on `HealthGlucoseSample`.
  - `struct HealthKitGlucoseFilter { let selectedSourceBundleID: String?; let acceptUserEntered: Bool; let ownBundleID: String; static let maximumAge: TimeInterval; static let maximumFutureSkew: TimeInterval; func readings(from samples: [HealthGlucoseSample], previous: [BloodGlucose], now: Date) -> [BloodGlucose] }`

- [ ] **Step 1: Register the two new files**

```bash
touch Trio/Sources/APS/CGM/HealthKitGlucoseFilter.swift TrioTests/HealthKitGlucoseFilterTests.swift
python3 docs/superpowers/plans/tools/add_to_xcodeproj.py Trio.xcodeproj/project.pbxproj AppGroupSource.swift HealthKitGlucoseFilter.swift
python3 docs/superpowers/plans/tools/add_to_xcodeproj.py Trio.xcodeproj/project.pbxproj GlucoseSmoothingTests.swift HealthKitGlucoseFilterTests.swift
```

- [ ] **Step 2: Write the failing tests** in `TrioTests/HealthKitGlucoseFilterTests.swift`

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `$TEST -only-testing:TrioTests/HealthKitGlucoseFilterTests | tail -40`
Expected: build failure, `cannot find 'HealthGlucoseSample' in scope`.

- [ ] **Step 4: Implement** `Trio/Sources/APS/CGM/HealthKitGlucoseFilter.swift`

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `$TEST -only-testing:TrioTests/HealthKitGlucoseFilterTests | tail -40`
Expected: `** TEST SUCCEEDED **`, 11 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Trio/Sources/APS/CGM/HealthKitGlucoseFilter.swift TrioTests/HealthKitGlucoseFilterTests.swift Trio.xcodeproj/project.pbxproj
git commit -m "Decide which Apple Health glucose samples count as CGM readings

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: HealthKitGlucoseSource and its anchor store

**Files:**
- Create: `Trio/Sources/APS/CGM/HealthKitGlucoseSource.swift`
- Create: `TrioTests/HealthKitAnchorStoreTests.swift`
- Modify: `Trio.xcodeproj/project.pbxproj` (via helper)

**Interfaces:**
- Consumes: `HealthGlucoseSample.init(_: HKQuantitySample)`, `HealthKitGlucoseFilter` (Task 2); `GlucoseTrendCalculator.maximumSpan` (Task 1); `GlucoseSource` (`Trio/Sources/APS/CGM/GlucoseSource.swift:9`); `AppleHealthConfig.healthBGObject` (`Trio/Sources/Services/HealthKit/HealthKitManager.swift:39`); `FetchGlucoseManager.newGlucoseFromCgmManager(newGlucose:)`; `GlucoseSourceKey.description`.
- Produces:
  - `struct HealthKitAnchorStore { init(defaults: UserDefaults = .standard); func anchor(for sourceBundleID: String) -> HKQueryAnchor?; func save(_ anchor: HKQueryAnchor, for sourceBundleID: String) }`
  - `final class HealthKitGlucoseSource: GlucoseSource` with `init(healthStore: HKHealthStore, anchorStore: HealthKitAnchorStore = HealthKitAnchorStore(), settings: @escaping () -> HealthKitGlucoseSource.Settings, glucoseManager: FetchGlucoseManager?)`, `func start()`, `func stop()`.
  - `struct HealthKitGlucoseSource.Settings { let sourceBundleID: String?; let acceptUserEntered: Bool }`
  - `static func requestReadAuthorization(_ store: HKHealthStore) async throws` and `static func glucoseSources(_ store: HKHealthStore) async -> [HKSource]` on `HealthKitGlucoseSource`.

- [ ] **Step 1: Register the two new files**

```bash
touch Trio/Sources/APS/CGM/HealthKitGlucoseSource.swift TrioTests/HealthKitAnchorStoreTests.swift
python3 docs/superpowers/plans/tools/add_to_xcodeproj.py Trio.xcodeproj/project.pbxproj AppGroupSource.swift HealthKitGlucoseSource.swift
python3 docs/superpowers/plans/tools/add_to_xcodeproj.py Trio.xcodeproj/project.pbxproj GlucoseSmoothingTests.swift HealthKitAnchorStoreTests.swift
```

- [ ] **Step 2: Write the failing tests** in `TrioTests/HealthKitAnchorStoreTests.swift`

```swift
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
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `$TEST -only-testing:TrioTests/HealthKitAnchorStoreTests | tail -40`
Expected: build failure, `cannot find 'HealthKitAnchorStore' in scope`.

- [ ] **Step 4: Implement** `Trio/Sources/APS/CGM/HealthKitGlucoseSource.swift`

```swift
import Combine
import Foundation
import HealthKit
import LoopKit
import LoopKitUI

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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `$TEST -only-testing:TrioTests/HealthKitAnchorStoreTests | tail -40`
Expected: `** TEST SUCCEEDED **`, 3 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Trio/Sources/APS/CGM/HealthKitGlucoseSource.swift TrioTests/HealthKitAnchorStoreTests.swift Trio.xcodeproj/project.pbxproj
git commit -m "Read CGM glucose from Apple Health with an observer and a per-source anchor

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Wire Apple Health in as a CGM type

**Files:**
- Modify: `Trio/Sources/APS/CGM/CGMType.swift` (enum, `displayName`, `appURL`, `subtitle`)
- Modify: `Trio/Sources/Models/TrioSettings.swift:26-27` (properties) and the decoder next to `cgmPluginIdentifier` (~line 168)
- Modify: `Trio/Sources/APS/Devices/DeviceCatalog.swift:393` (catalog entry)
- Modify: `Trio/Sources/APS/FetchGlucoseManager.swift` (injection ~line 47, `glucoseSource` didSet ~line 158, factory switch ~line 239)
- Modify: `Trio/Sources/Modules/Home/View/HomeRootView.swift:333-336` and `Trio/Sources/Modules/CGMSettings/View/CGMRootView.swift:148-151` (sheet switches)
- Test: `TrioTests/DeviceCatalogTests.swift` (existing `testAllCGMTypesCovered`), `TrioTests/CGMManagerAlertOwnershipTests.swift:27`

**Interfaces:**
- Consumes: `HealthKitGlucoseSource(healthStore:settings:glucoseManager:)`, `.start()`, `.stop()`, `HealthKitGlucoseSource.Settings` (Task 3).
- Produces: `CGMType.appleHealth` (raw value `"appleHealth"`); `TrioSettings.appleHealthCGMSourceBundleID: String?`; `TrioSettings.appleHealthCGMAcceptUserEntered: Bool`.

- [ ] **Step 1: Add the failing ownership expectation.** In `TrioTests/CGMManagerAlertOwnershipTests.swift`, change the loop in `nonOwnerSources`:

```swift
    @Test("nightscout / simulator / Apple Health sources → no owner") func nonOwnerSources() {
        for source in [CGMType.nightscout, .simulator, .appleHealth] {
            #expect(CGMManagerAlertOwnership.owningApp(manager: nil, sourceType: source) == nil)
        }
    }
```

- [ ] **Step 2: Add the enum case only**, in `CGMType.swift` after `case xdrip`:

```swift
    case appleHealth
```
and in `displayName` after the `.xdrip` case:
```swift
        case .appleHealth:
            return "Apple Health"
```
and in `appURL` extend the nil group, which today reads `case .nightscout,` / `.none:`, to:
```swift
        case .appleHealth,
             .nightscout,
             .none:
            return nil
```
and in `subtitle` after `.xdrip`:
```swift
        case .appleHealth:
            return String(
                localized: "Reads glucose that a CGM app such as Instara (Perlanova) writes to Apple Health",
                comment: "Apple Health CGM source subtitle"
            )
```

- [ ] **Step 3: Run the catalog and ownership tests to verify the catalog test fails**

Run: `$TEST -only-testing:TrioTests/DeviceCatalogTests -only-testing:TrioTests/CGMManagerAlertOwnershipTests | tail -40`
Expected: a build failure listing every non-exhaustive `switch` over `CGMType` (at least `FetchGlucoseManager.swift`, `HomeRootView.swift`, `CGMRootView.swift`). Fix those in Step 4, then rerun; `testAllCGMTypesCovered` must then fail with `CGMType.appleHealth is missing from the catalog`.

- [ ] **Step 4: Make the switch sites compile.**

In `HomeRootView.swift` and `CGMRootView.swift`, add `.appleHealth` to the case list that opens `CustomCGMOptionsView`:
```swift
                case .appleHealth,
                     .nightscout,
                     .none,
                     .simulator,
                     .xdrip:
```

In `TrioSettings.swift`, after `var cgmPluginIdentifier: String = ""`:
```swift
    /// Bundle id of the app whose Apple Health glucose Trio treats as CGM readings.
    var appleHealthCGMSourceBundleID: String?
    /// Testing aid: also accept glucose typed into Health by hand.
    var appleHealthCGMAcceptUserEntered: Bool = false
```
and in `init(from:)`, right after the `cgmPluginIdentifier` block:
```swift
        if let appleHealthCGMSourceBundleID = try? container.decode(String.self, forKey: .appleHealthCGMSourceBundleID) {
            settings.appleHealthCGMSourceBundleID = appleHealthCGMSourceBundleID
        }

        if let appleHealthCGMAcceptUserEntered = try? container.decode(Bool.self, forKey: .appleHealthCGMAcceptUserEntered) {
            settings.appleHealthCGMAcceptUserEntered = appleHealthCGMAcceptUserEntered
        }
```

In `FetchGlucoseManager.swift`, add next to the other injections:
```swift
    @Injected() var healthKitStore: HKHealthStore!
```
at the top of the `glucoseSource` `didSet`, before `cgmStatusSubscriptions.removeAll()`:
```swift
            // The Apple Health source holds an observer query and background delivery; release them on swap.
            (oldValue as? HealthKitGlucoseSource)?.stop()
```
and in the factory `switch`, after `.xdrip`:
```swift
            case .appleHealth:
                let source = HealthKitGlucoseSource(
                    healthStore: healthKitStore,
                    settings: { [weak self] in
                        HealthKitGlucoseSource.Settings(
                            sourceBundleID: self?.settingsManager.settings.appleHealthCGMSourceBundleID,
                            acceptUserEntered: self?.settingsManager.settings.appleHealthCGMAcceptUserEntered ?? false
                        )
                    },
                    glucoseManager: self
                )
                source.start()
                glucoseSource = source
```

- [ ] **Step 5: Rerun to confirm only the catalog test fails**

Run: `$TEST -only-testing:TrioTests/DeviceCatalogTests -only-testing:TrioTests/CGMManagerAlertOwnershipTests | tail -40`
Expected: build succeeds; `testAllCGMTypesCovered` fails with `CGMType.appleHealth is missing from the catalog`; ownership tests pass.

- [ ] **Step 6: Add the catalog entry** in `DeviceCatalog.swift`, after the `.xdrip` entry:

```swift
        CGMCatalogEntry(.native(.appleHealth), manufacturer: .otherSources),
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `$TEST -only-testing:TrioTests/DeviceCatalogTests -only-testing:TrioTests/CGMManagerAlertOwnershipTests | tail -40`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Trio/Sources/APS/CGM/CGMType.swift Trio/Sources/Models/TrioSettings.swift Trio/Sources/APS/Devices/DeviceCatalog.swift Trio/Sources/APS/FetchGlucoseManager.swift Trio/Sources/Modules/Home/View/HomeRootView.swift Trio/Sources/Modules/CGMSettings/View/CGMRootView.swift TrioTests/CGMManagerAlertOwnershipTests.swift
git commit -m "Offer Apple Health as a CGM source

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Do not write Apple Health readings back to Health

**Files:**
- Modify: `Trio/Sources/APS/Storage/GlucoseStorage.swift:254-262` (`configureGlucoseEntry`)
- Test: `TrioTests/CoreDataTests/GlucoseStorageTests.swift`

**Interfaces:**
- Consumes: `CGMType.appleHealth`, `TrioSettings.cgm` (Task 4); `GlucoseStorage.getGlucoseNotYetUploadedToHealth()`.
- Produces: readings stored while `settings.cgm == .appleHealth` have `isUploadedToHealth == true`.

- [ ] **Step 1: Write the failing tests.** In `GlucoseStorageTests`, add below `@Injected() var storage: GlucoseStorage!`:

```swift
    @Injected() var settingsManager: SettingsManager!
```
and add these tests:

```swift
    @Test("Readings from the Apple Health source are not queued for upload to Health")
    func testAppleHealthReadingsSkipHealthUpload() async throws {
        let previousCGM = settingsManager.settings.cgm
        defer { settingsManager.settings.cgm = previousCGM }
        settingsManager.settings.cgm = .appleHealth

        try await storage.storeGlucose([BloodGlucose(direction: .flat, date: 1, dateString: Date(), glucose: 141)])

        let stored = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 141"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]
        #expect(stored?.first?.isUploadedToHealth == true)
        let pending = try await storage.getGlucoseNotYetUploadedToHealth()
        #expect(!pending.contains { $0.glucose == 141 })
    }

    @Test("Readings from other sources are still queued for upload to Health")
    func testOtherSourceReadingsQueueHealthUpload() async throws {
        let previousCGM = settingsManager.settings.cgm
        defer { settingsManager.settings.cgm = previousCGM }
        settingsManager.settings.cgm = .xdrip

        try await storage.storeGlucose([BloodGlucose(direction: .flat, date: 1, dateString: Date(), glucose: 142)])

        let stored = try await coreDataStack.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "glucose == 142"),
            key: "date",
            ascending: false
        ) as? [GlucoseStored]
        #expect(stored?.first?.isUploadedToHealth == false)
    }
```

- [ ] **Step 2: Run the tests to verify the first fails**

Run: `$TEST -only-testing:TrioTests/GlucoseStorageTests | tail -40`
Expected: `testAppleHealthReadingsSkipHealthUpload` fails (`isUploadedToHealth` is false); `testOtherSourceReadingsQueueHealthUpload` passes.

- [ ] **Step 3: Implement.** In `configureGlucoseEntry`, replace `entry.isUploadedToHealth = false` with:

```swift
        // Readings that came from Apple Health are already there; uploading them would duplicate every value.
        entry.isUploadedToHealth = settingsManager.settings.cgm == .appleHealth
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `$TEST -only-testing:TrioTests/GlucoseStorageTests | tail -40`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Trio/Sources/APS/Storage/GlucoseStorage.swift TrioTests/CoreDataTests/GlucoseStorageTests.swift
git commit -m "Keep Apple Health CGM readings from being written back to Health

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Apple Health settings section and translations

**Files:**
- Modify: `Trio/Sources/Modules/CGMSettings/CGMSettingsStateModel.swift` (published state, subscriptions, refresh)
- Modify: `Trio/Sources/Modules/CGMSettings/View/CustomCGMOptionsView.swift:81-86` (section routing), `onAppear` (~line 138), new `appleHealthConfigurationSection`
- Modify: `Trio/Sources/Localizations/Main/Localizable.xcstrings` (via helper)

**Interfaces:**
- Consumes: `HealthKitGlucoseSource.requestReadAuthorization(_:)`, `HealthKitGlucoseSource.glucoseSources(_:)` (Task 3); `TrioSettings.appleHealthCGMSourceBundleID`, `.appleHealthCGMAcceptUserEntered`, `CGMType.appleHealth` (Task 4); `GlucoseStorage.lastGlucoseDate()`.
- Produces: `struct AppleHealthSourceOption: Identifiable, Hashable { let bundleID: String; let name: String }`; on `CGMSettings.StateModel`: `@Published var appleHealthSourceBundleID: String?`, `@Published var appleHealthAcceptUserEntered: Bool`, `@Published var appleHealthSources: [AppleHealthSourceOption]`, `@Published var lastGlucoseDate: Date?`, `@MainActor func refreshAppleHealth() async`.

- [ ] **Step 1: State model.** In `CGMSettingsStateModel.swift`, above `extension CGMSettings {`:

```swift
struct AppleHealthSourceOption: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}
```

Inside `StateModel`, add with the other injections and published properties:

```swift
        @Injected() var healthKitStore: HKHealthStore!
        @Injected() var glucoseStorage: GlucoseStorage!

        @Published var appleHealthSourceBundleID: String?
        @Published var appleHealthAcceptUserEntered = false
        @Published var appleHealthSources: [AppleHealthSourceOption] = []
        @Published var lastGlucoseDate: Date?
```

In `subscribe()`, next to the existing `subscribeSetting(\.smoothGlucose, ...)` line:

```swift
            subscribeSetting(
                \.appleHealthCGMSourceBundleID,
                on: $appleHealthSourceBundleID,
                initial: { appleHealthSourceBundleID = $0 }
            )
            subscribeSetting(
                \.appleHealthCGMAcceptUserEntered,
                on: $appleHealthAcceptUserEntered,
                initial: { appleHealthAcceptUserEntered = $0 }
            )
```

And add the method in the class body:

```swift
        /// Asks for read access (iOS shows the sheet only the first time) and reloads the apps that write glucose.
        @MainActor func refreshAppleHealth() async {
            do {
                try await HealthKitGlucoseSource.requestReadAuthorization(healthKitStore)
            } catch {
                warning(.service, "Apple Health read authorization failed", error: error)
            }
            appleHealthSources = await HealthKitGlucoseSource.glucoseSources(healthKitStore)
                .map { AppleHealthSourceOption(bundleID: $0.bundleIdentifier, name: $0.name) }
            lastGlucoseDate = glucoseStorage.lastGlucoseDate()
        }
```
Add `import HealthKit` at the top of the file.

- [ ] **Step 2: View routing.** In `CustomCGMOptionsView.body`, extend the `if/else` chain:

```swift
                        } else if cgmCurrent.type == .appleHealth {
                            appleHealthConfigurationSection
                        } else if cgmCurrent.type == .simulator {
```
and in `.onAppear` add:

```swift
                    if cgmCurrent.type == .appleHealth {
                        Task { await state.refreshAppleHealth() }
                    }
```

- [ ] **Step 3: The section.** Add to `CustomCGMOptionsView`, after `xDripConfigurationSection`:

```swift
        /// No reading for this long means Instara is not sharing, or Trio may not read; iOS never reports read denial.
        private static let appleHealthSilenceLimit: TimeInterval = 15 * 60

        var appleHealthConfigurationSection: some View {
            Group {
                Section(
                    header: Text("Configuration"),
                    content: {
                        if state.appleHealthSources.isEmpty {
                            Text(
                                "No app has written blood glucose to Apple Health yet. Turn on Apple Health sharing in Instara first."
                            )
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                        } else {
                            Picker("Source app", selection: $state.appleHealthSourceBundleID) {
                                Text("None").tag(String?.none)
                                ForEach(state.appleHealthSources) { option in
                                    Text(option.name).tag(Optional(option.bundleID))
                                }
                            }
                        }

                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            appleHealthLastReadingRow(now: context.date)
                        }

                        Button("Request Apple Health access") {
                            Task { await state.refreshAppleHealth() }
                        }
                        Text("If you declined access earlier, allow it in Health › Profile › Apps › Trio.")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                ).listRowBackground(Color.chart)

                Section {
                    Label(
                        "Apple Health cannot be read while the iPhone is locked. Trio receives no new glucose and does not loop until you unlock it.",
                        systemImage: "lock.iphone"
                    )
                    .font(.footnote)
                }.listRowBackground(Color.chart)

                Section {
                    Toggle("Accept manually entered values (testing only)", isOn: $state.appleHealthAcceptUserEntered)
                    if state.appleHealthAcceptUserEntered {
                        Text("TEST MODE: manually entered values are treated as CGM readings.")
                            .font(.footnote)
                            .bold()
                            .foregroundStyle(Color.red)
                    }
                }.listRowBackground(Color.chart)
            }
        }

        @ViewBuilder private func appleHealthLastReadingRow(now: Date) -> some View {
            if let date = state.lastGlucoseDate {
                let minutes = Int(now.timeIntervalSince(date) / 60)
                HStack {
                    Text("Last reading")
                    Spacer()
                    Text(date, style: .time)
                    Text("\(minutes) min ago").foregroundStyle(Color.secondary)
                }
                if now.timeIntervalSince(date) > Self.appleHealthSilenceLimit {
                    Text(
                        "No glucose from Apple Health for over 15 minutes. Check that Instara is sharing to Apple Health and that Trio may read it."
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
                }
            } else {
                HStack {
                    Text("Last reading")
                    Spacer()
                    Text("No reading yet").foregroundStyle(Color.secondary)
                }
            }
        }
```

- [ ] **Step 4: Build to catch compile errors**

Run: `xcodebuild build -workspace Trio.xcworkspace -scheme Trio -destination 'platform=iOS Simulator,name=iPhone 15 Pro' CODE_SIGNING_ALLOWED=NO | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Add the Turkish translations.** Create `apple-health-strings.json` in the repo root (it is deleted right after use and never committed):

```json
[
  {"key": "Reads glucose that a CGM app such as Instara (Perlanova) writes to Apple Health", "comment": "Apple Health CGM source subtitle", "tr": "Instara (Perlanova) gibi bir CGM uygulamasının Apple Sağlık'a yazdığı glukozu okur"},
  {"key": "No app has written blood glucose to Apple Health yet. Turn on Apple Health sharing in Instara first.", "comment": "Apple Health CGM: no source apps found", "tr": "Henüz hiçbir uygulama Apple Sağlık'a kan şekeri yazmadı. Önce Instara'da Apple Sağlık paylaşımını açın."},
  {"key": "Source app", "comment": "Apple Health CGM: picker for the app whose glucose is used", "tr": "Kaynak uygulama"},
  {"key": "Request Apple Health access", "comment": "Apple Health CGM: button asking for read permission", "tr": "Apple Sağlık erişimi iste"},
  {"key": "If you declined access earlier, allow it in Health › Profile › Apps › Trio.", "comment": "Apple Health CGM: where to grant read access later", "tr": "Erişimi daha önce reddettiyseniz Sağlık › Profil › Uygulamalar › Trio bölümünden izin verin."},
  {"key": "Apple Health cannot be read while the iPhone is locked. Trio receives no new glucose and does not loop until you unlock it.", "comment": "Apple Health CGM: permanent lock limitation warning", "tr": "iPhone kilitliyken Apple Sağlık okunamaz. Kilidi açana kadar Trio yeni glukoz almaz ve döngü çalışmaz."},
  {"key": "Accept manually entered values (testing only)", "comment": "Apple Health CGM: testing toggle", "tr": "Elle girilen değerleri kabul et (yalnızca test)"},
  {"key": "TEST MODE: manually entered values are treated as CGM readings.", "comment": "Apple Health CGM: shown while the testing toggle is on", "tr": "TEST MODU: elle girilen değerler CGM ölçümü gibi kullanılıyor."},
  {"key": "Last reading", "comment": "Apple Health CGM: label for the newest stored reading", "tr": "Son değer"},
  {"key": "%lld min ago", "comment": "Apple Health CGM: age of the newest reading in minutes", "tr": "%lld dk önce"},
  {"key": "No glucose from Apple Health for over 15 minutes. Check that Instara is sharing to Apple Health and that Trio may read it.", "comment": "Apple Health CGM: no data warning", "tr": "15 dakikadır Apple Sağlık'tan glukoz gelmedi. Instara'nın Apple Sağlık'a paylaştığını ve Trio'nun okuma izni olduğunu kontrol edin."},
  {"key": "No reading yet", "comment": "Apple Health CGM: no reading stored yet", "tr": "Henüz değer yok"}
]
```

Then run:
```bash
python3 docs/superpowers/plans/tools/add_xcstrings.py Trio/Sources/Localizations/Main/Localizable.xcstrings apple-health-strings.json
rm apple-health-strings.json
git diff --stat Trio/Sources/Localizations/Main/Localizable.xcstrings
```
Expected: `12 entries merged`; the diff touches only these entries (roughly 130 inserted lines, no deletions). `None` and `Configuration` already exist with Turkish translations and are not listed.

- [ ] **Step 6: Run the localization test suite**

Run: `$TEST -only-testing:TrioTests/LocalizationTests | tail -40`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Trio/Sources/Modules/CGMSettings/CGMSettingsStateModel.swift Trio/Sources/Modules/CGMSettings/View/CustomCGMOptionsView.swift Trio/Sources/Localizations/Main/Localizable.xcstrings
git commit -m "Add Apple Health CGM settings with source picker, lock warning and test mode

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Whole-branch verification

**Files:** none changed unless a check fails.

- [ ] **Step 1: Full test suite**

Run: `$TEST | tail -60`
Expected: `** TEST SUCCEEDED **`. Report any failure with its output; do not skip or disable tests.

- [ ] **Step 2: Locale check.** Dispatch the `locale-enforcer` agent on the diff `git diff i18n_tr...HEAD -- Trio/Sources`. Every new user-facing string must be localized and have a `tr` entry. Fix and commit any finding.

- [ ] **Step 3: Manual check in the iOS Simulator** (record the result in the handoff, pass or fail per line)
  1. Run Trio on `iPhone 15 Pro`. Open the Health app, Browse › Blood Glucose › Add Data, enter 110 mg/dL with the time set 5 minutes ago.
  2. In Trio: Settings › CGM › Apple Health. Grant read access. Expect "Health" in the source picker; pick it.
  3. Turn on "Accept manually entered values (testing only)". Expect the red TEST MODE line.
  4. Within a minute, expect 110 on the home screen with no arrow.
  5. In Health, add 125 mg/dL with the current time. 15 mg/dL over 5 minutes is 3.0 mg/dL/min, so expect 125 with ⇈ (DoubleUp).
  6. Turn the test switch off, add another value in Health. Expect it not to appear in Trio.
  7. With Trio's "Apple Health" upload setting on, confirm Health shows no duplicate Trio copy of these values.
  8. Switch Trio's CGM to "Glucose Simulator" and back; expect no crash and readings to resume.

- [ ] **Step 4: Report** what passed, what failed, and what needs a physical iPhone (lock behaviour, background wake-up, the real Instara app).
