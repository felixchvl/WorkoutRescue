# WorkoutRescue — signing & upload (Account Holder)

Félix is Admin in App Store Connect, but on an individual membership only the Account Holder can use
Certificates, Identifiers & Profiles. These steps must therefore be done by Bahey. ~10 minutes.

The project is already set to Team ID **JDP856P5D5** for both targets.

Requirements: **Xcode 27.x** (the project was created with Xcode 27; watchOS 26.0 deployment target).

1. Xcode → Settings → Apple Accounts → signed in with the Account Holder Apple Account.
2. Open `WorkoutRescue.xcodeproj` (open the `.xcodeproj` itself, not the folder: the folder also contains a
   `Package.swift` used only for tests).
3. Project navigator → **WorkoutRescue** project → for each target, **WorkoutRescue Watch App** and
   **WorkoutRescue**: *Signing & Capabilities* → *Automatically manage signing* checked, Team = Bahey Shalash.
   Xcode registers `com.felixchevalier.WorkoutRescue` and `com.felixchevalier.WorkoutRescue.watchkitapp`
   (HealthKit capability, read-only) on the account.
4. Run destination (top bar): **Any watchOS Device**. Scheme: **WorkoutRescue Watch App**.
5. **Product → Archive**.
6. Organizer → select the archive → **Validate App** (optional) → **Distribute App → App Store Connect → Distribute**.
   If asked, let Xcode create the App Store Connect app record (name: WorkoutRescue, primary language English,
   SKU: workoutrescue-001).

That's all. Félix then completes the App Store page and submits for review from App Store Connect.
Watch-only app: no iOS executable, no companion app. Export compliance is already declared
(`ITSAppUsesNonExemptEncryption = NO`).
