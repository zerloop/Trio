# Apple Health as CGM — Design

Date: 2026-09-25
Branch: `feature/apple-health-cgm` (from `i18n_tr`)

## Goal

Let Trio use blood glucose that a third-party CGM app writes to Apple Health as its CGM source. The immediate user is a single person using the Perlanova (Teljane Instara-1) sensor, whose official Instara-G1 app can share to Apple Health. Trio has no driver for this sensor and its Bluetooth protocol is not public, so a native driver is out of reach.

Success: with the Instara app sharing to Health and the new source selected, Trio stores each reading, shows it with a trend arrow, and runs the loop — whenever the iPhone is unlocked.

## Known limitation (accepted)

HealthKit data is encrypted while the iPhone is locked; no app can read it then. While locked, Trio receives no new glucose; the loop's own stale-glucose gate stops it after 12 minutes without a new reading (`APSManager.swift`), while the home screen marks data stale after 6 minutes, and overnight protection is weak. On unlock, the backlog is read and the loop resumes. The user accepted this. The settings screen states it permanently.

## Out of scope

- Native Bluetooth driver for Instara-1.
- Sensor lifetime (21 days) / warm-up display: Health carries no session start, so it would be a guess.
- Propagating deletions made in Health.

## Architecture

A new built-in source, parallel to xDrip4iOS, not a LoopKit `CGMManager` plugin.

### Components

1. **`CGMType.appleHealth`** (`Trio/Sources/APS/CGM/CGMType.swift`): new case with `displayName`, `subtitle`, `appURL = nil`, `externalLink = nil`. Update every switch over `CGMType`:
   - `FetchGlucoseManager.swift` source factory creates `HealthKitGlucoseSource`.
   - `HomeRootView.swift` and `CGMRootView.swift` sheet switches: route to `CustomCGMOptionsView`, like `.xdrip`.
   - `CGMManagerAlertOwnership.swift`: Trio owns alerts, like `.nightscout`.
   - `DeviceCatalog.swift`: `CGMCatalogEntry(.native(.appleHealth), manufacturer: .otherSources)` with a subtitle naming Perlanova (Instara).
2. **`HealthKitGlucoseSource`** (new, `Trio/Sources/APS/CGM/HealthKitGlucoseSource.swift`): conforms to `GlucoseSource`.
   - On start: request read authorization for blood glucose, register an `HKObserverQuery` on `bloodGlucose`, and call `enableBackgroundDelivery(for: bloodGlucose, frequency: .immediate)`.
   - On observer fire, and on each `fetch(_:)` tick of the 1-minute timer, run an `HKAnchoredObjectQuery` from the persisted anchor.
   - Samples are filtered and converted by `HealthKitGlucoseFilter`. New readings go through `glucoseManager.newGlucoseFromCgmManager(newGlucose:)` from the observer path; `fetch` returns them from the timer path. Central dedup makes double delivery harmless.
   - On teardown (source changed): stop the observer query and `disableBackgroundDelivery(for: bloodGlucose)` only. Never call `disableAllBackgroundDelivery`.
   - Anchor persisted (archived `HKQueryAnchor`) keyed by the selected source bundle id; changing the source discards it, so the last 24 h are rescanned.
   - Reference implementation: the source removed in `4995754db` (`git show 4995754db -- '*HealthKitManager.swift'`).
3. **`HealthKitGlucoseFilter`** (pure, no HealthKit types in its interface so it is unit-testable). Input: a value type `HealthGlucoseSample { uuid, date, mgdl, sourceBundleID, wasUserEntered }`, the selected bundle id, the accept-user-entered flag, Trio's bundle id, and `now`. Output: `[BloodGlucose]` sorted by date. Rules:
   - keep only `sourceBundleID == selected`;
   - always drop `sourceBundleID == Trio's bundle id`;
   - drop `wasUserEntered` unless the test flag is on;
   - drop `date < now - 24h` and `date > now + 5 min`;
   - value: mg/dL, rounded to Int; set both `sgv` and `glucose` (storage saves `glucose`); `type = "sgv"`; `id = uuid`; `direction` from `GlucoseTrendCalculator`.
   - The HealthKit adapter converts `HKQuantitySample` to `HealthGlucoseSample` (unit `mg/dL`, `HKMetadataKeyWasUserEntered`, `sourceRevision.source.bundleIdentifier`).
4. **`GlucoseTrendCalculator`** (pure): given a reading and the previous readings (new batch plus the latest stored ones), compute the rate in mg/dL/min against the most recent earlier reading 4–15 min older.
   - `≥ 3` → `doubleUp`; `[2, 3)` → `singleUp`; `[1, 2)` → `fortyFiveUp`; `(-1, 1)` → `flat`; `(-2, -1]` → `fortyFiveDown`; `(-3, -2]` → `singleDown`; `≤ -3` → `doubleDown`.
   - No reading in the 4–15 min window → `nil` (no arrow).
5. **No write-back**: when the source is `.appleHealth`, readings stored from it are marked `isUploadedToHealth = true` (new parameter on `GlucoseStorage.configureGlucoseEntry`/`storeGlucose`), so `HealthKitManager.uploadGlucose` does not duplicate them.
6. **Settings** (`TrioSettings`, with decode fallbacks like existing keys):
   - `appleHealthCGMSourceBundleID: String?`
   - `appleHealthCGMAcceptUserEntered: Bool = false`
7. **UI**: an Apple Health section in `CustomCGMOptionsView`:
   - source-app picker listing apps that have written blood glucose to Health (`HKSourceQuery`); empty state "Turn on Apple Health sharing in Instara first";
   - last reading: value, time, age in minutes;
   - permanent warning: HealthKit cannot be read while the iPhone is locked, and the loop does not run then;
   - "Open Health permissions" button; a "no data for N minutes, check Health permissions" warning when the last reading is older than 15 min (iOS never reports read denial);
   - toggle "Accept manually entered values (testing only)"; while on, a red TEST MODE label.

### Data flow

Instara → Health → (observer | 1-min timer) → anchored query → `HealthKitGlucoseFilter` + `GlucoseTrendCalculator` → `FetchGlucoseManager.glucoseStoreAndHeartDecision` (calibration, backfill vs new, 3.5-min dedup, storage, smoothing, loop heartbeat). Nothing downstream changes.

Heartbeat: the source provides no BLE heartbeat (`cgmProvidesHeartbeat` stays false); background wake-ups come from the pump heartbeat and HealthKit background delivery.

## Error handling

| Case | Behaviour |
|---|---|
| Device locked (`HKError.errorDatabaseInaccessible`) | Log, deliver nothing, keep anchor; next observer fire/tick after unlock reads the backlog. Older readings take the backfill path. |
| Read permission denied | Queries return empty; settings shows the "no data" warning. |
| Source app not selected | Source delivers nothing; settings prompts to pick one. |
| Data late or stopped | The loop's stale-glucose gate (12 min) stops the loop; the home screen marks data stale after 6 min; settings shows reading age. |
| Source changed | Anchor discarded, 24 h rescan, central dedup drops duplicates. |
| Sample deleted in Health | Ignored. |
| Switched to another CGM | Observer stopped, background delivery disabled for blood glucose only. |

## Localization

Every new user-facing string uses `String(localized:comment:)` and is added to `Trio/Sources/Localizations/Main/Localizable.xcstrings` with a Turkish translation. The locale-enforcer agent reviews the change.

## Testing

- Unit (Swift Testing), new `TrioTests/HealthKitGlucoseFilterTests.swift` and `TrioTests/GlucoseTrendCalculatorTests.swift`:
  - filter: selected app kept; other app dropped; Trio's own dropped; user-entered dropped/kept by flag; >24 h old and >5 min future dropped; mmol/L input converted; `sgv == glucose`;
  - trend: every threshold boundary, both directions; no earlier reading → `nil`; earlier reading outside 4–15 min → `nil`.
- Existing: `DeviceCatalogTests`, `CGMManagerAlertOwnershipTests` pass with the new case (extend the latter for `.appleHealth`).
- `GlucoseStorage` test: readings stored with the Health flag are not selected by the "not yet uploaded to Health" predicate.
- Manual (iOS Simulator): enter blood glucose in the Health app, select Health (`com.apple.Health`, which the picker lists once it has written a sample) as source app, enable the test toggle; verify the reading appears, the arrow is computed after a second entry, and the loop runs. Lock behaviour and background wake-up need a physical iPhone.
