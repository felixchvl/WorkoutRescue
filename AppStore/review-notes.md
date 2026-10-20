# Notes pour App Review (à coller dans « App Review Information → Notes »)

WorkoutRescue is an independent, watch-only app (no iOS companion app). It lets a user make a personal copy of the
workouts stored in Apple Health on their Apple Watch, for example when the watch can no longer sync with an iPhone.

HealthKit usage
- Read-only. The app requests read access only (requestAuthorization with an empty share set). It never writes,
  modifies or deletes Health data and does not use workout sessions.
- Types read: workouts, workout routes, and workout-related quantities (heart rate, heart rate recovery,
  active/basal energy, cycling / walking-running / swimming distance, cycling speed/power/cadence/FTP, running
  speed/power/stride length/vertical oscillation/ground contact time, steps, flights climbed, swimming strokes,
  physical effort, exercise minutes, workout effort scores). Every type requested is included in the export.
- HealthKit data is not used for advertising, is not stored in iCloud and is not shared with the developer or third
  parties.

Export
- Data leaves the watch only when the user taps "Export Workout", "Export JSON", "Export GPX" or "Send All to
  Receiver", and only to the HTTPS address the user typed in Settings (bearer token stored in the Keychain).
- The receiving server is operated by the user (a reference receiver script is provided to users). The developer
  operates no server and receives no data.

How to review without personal Health data
1. Open the app → Settings → turn on "Demo mode". The app then shows three FICTIONAL workouts, clearly labelled
   "DEMO – fictional data". They are generated in code and never read from or written to Apple Health.
2. Back on the main screen → Workouts → open "Cycling" to see the route point count, sample counts and export buttons.
3. Turn Demo mode off and tap "Allow Health Access" to see the read-only HealthKit permission sheet. With workouts
   recorded on the review device, the list shows them newest first.
4. Exporting requires an HTTPS receiver. [OPTION — only if the developer decides to provide one:
   Settings → receiver `https://…` and token `…`, available until <date>. This test receiver runs in
   demo-only mode: it accepts only the fictional demo workouts and refuses any real Health data (HTTP 403),
   so please keep Demo mode ON to try "Export Workout" and "Send All to Receiver".] Without a receiver,
   "Test Connection" reports the network error, which is the expected behaviour.

Contact: [phone / e-mail to add]
