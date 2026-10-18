// swift-tools-version: 6.2
// Test harness for the portable part of the watch app. It compiles the exact same source files
// as the Xcode target ("WorkoutRescue Watch App/Shared") with the same default MainActor
// isolation, so `swift test` exercises the shipping code on macOS without a watchOS simulator.
// The Xcode project is unaffected: open WorkoutRescue.xcodeproj explicitly.
import PackageDescription

let package = Package(
    name: "WorkoutRescueCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "WorkoutRescueCore", targets: ["WorkoutRescueCore"])],
    targets: [
        .target(
            name: "WorkoutRescueCore",
            path: "WorkoutRescue Watch App/Shared",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]),
        .testTarget(
            name: "WorkoutRescueCoreTests",
            dependencies: ["WorkoutRescueCore"],
            path: "Tests/WorkoutRescueCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
