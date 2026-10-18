# App Store — English (en-US)

**Name:** WorkoutRescue
**Subtitle (≤ 30):** Export workouts & GPS routes
**Promotional text (≤ 170):** Export your Apple Watch workout data.

## Description

WorkoutRescue makes a personal copy of the workouts stored on your Apple Watch — directly from the watch, without an iPhone.

It reads your workouts from Apple Health (HealthKit) in read-only mode, including GPS routes and workout metrics, and sends a complete archive to an HTTPS server that you control.

WHAT IT EXPORTS
• Workout details: activity, dates, duration, distance, energy, source device, metadata, laps and pauses
• Complete GPS routes: every point with timestamp, latitude, longitude, altitude, accuracy, speed and course — no smoothing, no simplification
• Time series recorded during the workout when available: heart rate, distance, speed, cycling power and cadence, running metrics, energy
• A versioned JSON archive (the complete record) and a standard GPX 1.1 track for mapping tools

HOW IT WORKS
• Runs independently on Apple Watch — no companion iPhone app
• Browse workouts newest first and review a workout before exporting it
• Export one workout or all of them; already-confirmed workouts are skipped
• A transfer counts as successful only when your server confirms the same SHA-256 checksum
• Works with the WorkoutRescue receiver, a small Python program you run on your own computer or server

PRIVACY
• Read-only Apple Health access: WorkoutRescue never writes, edits or deletes Health data
• No account, no ads, no tracking, no analytics
• Data leaves the watch only when you tap Export, and only to the server address you entered
• Your server token is stored in the watch Keychain

REQUIREMENTS
• Apple Watch with watchOS 26 or later, with Wi-Fi or cellular internet access
• An HTTPS endpoint you operate (for example the WorkoutRescue receiver behind your own domain)
• A Demo Mode with clearly labelled fictional workouts lets you try the app without Health data
