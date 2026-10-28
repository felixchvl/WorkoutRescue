# WorkoutRescue

Standalone (**watch-only**) Apple Watch app that reads the workouts stored in HealthKit on the watch (GPS routes,
heart rate, power, cadence, metadata…) and sends them over HTTPS to a server you control — no iPhone, no
WatchConnectivity. It was built to get workouts off an Apple Watch whose pairing with its iPhone broke.

**Status (2026-10-28):** approved on the App Store on 2026-10-22 (published through Bahey Shalash's developer team,
`JDP856P5D5`). Used for real on 2026-10-22: 27 workouts (13 → 22 Oct 2026) recovered, checked by
`receiver/verify.py` (0 problems) and imported into Health through HealthFit. The 94 rides of the gap before that
(11 Sep → 14 Oct) were rebuilt from Arc Timeline with `reconstruct/`.

## What it can and cannot recover: the ~8-day window

The main finding of the real recovery, worth knowing before trying again:

- **watchOS only lets an app read HealthKit data newer than `HKHealthStore.earliestPermittedSampleDate()`.** On an
  Apple Watch Ultra 2 (watchOS 26) that was about **8 days** for samples (heart rate, distance, routes) and about
  **9 days** for `HKWorkout` objects. The app's queries have no date predicate; the cut-off comes from the OS.
- **The window slides every day.** Run *Export All* as soon as possible: every day of delay is a day of workouts the
  API will never return again.
- Older workouts are returned by **no** App Store app, this one included. Here the pairing broke at the end of July
  and the workouts from 1 Sep to 13 Oct were unreadable. Whether watchOS deletes them or keeps them waiting for a
  sync is not documented; the watch still showed ~130 MB of Health data (Settings → General → Storage), more than
  8 days should take.
- **A workout that straddles the cut-off comes back truncated:** the ride of 14 Oct 19:33 came back with 250 m
  instead of 4.3 km because its first samples were already out of the window.
- Dead ends: watchOS 27's `earliestAuthorizedSampleDate(for:)` only reports the start of a *limited* access the
  user granted, it does not widen the window; the watch's system date cannot be changed.
- What worked for the gap: another recording of the same rides (Arc Timeline locations, map-matched with a local
  OSRM, see `reconstruct/`). No heart rate is invented for rebuilt rides.

## Non-destruction guarantee

- HealthKit is **read-only**: `requestAuthorization(toShare: [], read: …)` and queries only
  (`HKSampleQueryDescriptor`, `HKWorkoutRouteQueryDescriptor`, `HKQuantitySeriesSampleQueryDescriptor`).
  No `save`, `delete`, `HKWorkoutSession` or `HKWorkoutBuilder` in the code (`grep` confirms it).
- No data leaves the watch without an explicit tap (Export buttons), and only to the address typed in Settings.
- The receiver never overwrites or deletes a file.
- Recovered data never goes into git: `receiver/exports/`, `receiver/.env` and logs are ignored.

## Where to find what

| Path | Content |
|---|---|
| `WorkoutRescue Watch App/Shared/` | portable code (JSON v2 model, GPX, HTTPS client, pipeline, registry, demo) — built into the app **and** tested on macOS |
| `WorkoutRescue Watch App/Core/` | HealthKit (read-only), Keychain, log, app state |
| `WorkoutRescue Watch App/Views/` | watchOS SwiftUI screens |
| `Tests/WorkoutRescueCoreTests/` | XCTest suite run by `swift test` (macOS) |
| `WorkoutRescue Watch AppTests/` | watchOS/HealthKit tests (need a watchOS ≥ 26 simulator) |
| `receiver/` | Python receiver (stdlib), integrity checker, JSON → FIT/TCX converter for HealthFit, tests |
| `reconstruct/` | rebuild rides from Arc Timeline: trip extraction, OSRM map-matching, FIT generation, review pages |
| `scripts/` | `test-all.sh`, `e2e.sh`, `make-icon.swift` |
| `docs/` | recovery runbook, JSON schema, distribution procedure (in French) |
| `AppStore/` | FR/EN texts, keywords, privacy policy, App Review notes, checklist |

## Screens

Dashboard (number of workouts, last scan, receiver status, last export) → Workouts (newest first: type, date,
duration, distance) → Detail (GPS points, heart rate samples, warnings, Export Workout / JSON / GPX) · Export All
(sequential, skips confirmed exports) · Settings (address, token, connection test, Demo mode) · Diagnostics
(HealthKit / Export / Network).

## Commands

```bash
./scripts/test-all.sh                       # swift test + receiver tests + end to end
xcodebuild -project WorkoutRescue.xcodeproj -scheme "WorkoutRescue Watch App" \
  -configuration Release -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
```

`Package.swift` at the root is only a test bench: it builds `WorkoutRescue Watch App/Shared` for macOS with the same
default isolation (`MainActor`) as the Xcode target. Open `WorkoutRescue.xcodeproj` explicitly. The SwiftPM build
folder must live outside the repository (`--scratch-path`, already done by the scripts): extended attributes of an
iCloud-synced folder break the ad hoc signing of the test bundle. Signing and upload: `SIGNING-FOR-BAHEY.md`.

## Other known limits

- Export runs in the foreground: keep the wrist raised; a network drop is caught by the retries and by resuming
  *Export All*. Background `URLSession` upload is not implemented.
- Data not exported in v2: see `docs/JSON-SCHEMA.md`.
