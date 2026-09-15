# Workout Rescue

Workout Rescue is a watch-only, independent watchOS app intended to read and export historical workouts stored in HealthKit on the Apple Watch. It has no iPhone companion target and does not use WatchConnectivity.

## Non-negotiable safety guarantee

The app is read-only. It requests **only HealthKit read access** and contains no HealthKit save, delete, workout session, or mutation API. Exporting never marks data as expendable and never changes the original workout, route, samples, metadata, or source.

## Current vertical slice

The app targets watchOS 26.0 and includes:

- independent Watch-only configuration (`WKWatchOnly`);
- HealthKit entitlement and a clear `NSHealthShareUsageDescription`;
- direct, read-only authorization on Apple Watch;
- historical `HKWorkout` query, newest first;
- workout list and read-only summary/detail display;
- a bounded in-app diagnostic log which never writes health samples to system logs;
- mock repository support for UI development without HealthKit data;
- versioned, deterministic ISO-8601 JSON and isolated GPX 1.1 export models.

## Planned archive contents

`WorkoutExport` version 1 carries the workout UUID/activity/source, timestamps, distance and active energy summaries, safely stringified metadata, normalized quantity samples (identifier, timestamp, value and canonical unit), and complete route points. GPX is produced only if at least one route exists; JSON is the archival source of truth.

## HealthKit types

The read request includes `HKWorkout`, `HKWorkoutRoute`, heart rate, active energy, running/walking distance, cycling distance, running speed/power/stride/vertical oscillation/ground contact time, cycling speed, and cycling cadence. Availability and access are always treated as partial: a missing sample or route is never an error by itself.

## Network API (next slice)

The app will make direct HTTPS requests from watchOS using `URLSession`, with a user-supplied endpoint and bearer token:

`POST /api/workouts/{uuid}/metadata` with `application/json`

`POST /api/workouts/{uuid}/route` with `application/gpx+xml`

No endpoint, token, or health data is sent until the owner expressly uses an export action.

## Validation

The Watch App target builds with Xcode 27 / watchOS 27 SDK at a watchOS 26.0 deployment target for both `arm64` and `arm64_32`. The local Xcode installation is missing its Watch-only Application Stub, so the outer App Store container cannot currently be built or archived; this does not affect the successful compilation of the watch target.

## Apple references

- [Independent watchOS apps](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps)
- [HealthKit authorization](https://developer.apple.com/documentation/healthkit/hkhealthstore/requestauthorization%28toshare%3Aread%3Acompletion%3A%29)
- [HKSampleQuery](https://developer.apple.com/documentation/healthkit/hksamplequery)
- [HKWorkoutRouteQuery](https://developer.apple.com/documentation/healthkit/hkworkoutroutequery)
