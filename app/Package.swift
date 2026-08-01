// swift-tools-version:5.9
import PackageDescription

// Token Tab — native macOS menu-bar app (Approach A, the "keeper").
//
// A SwiftUI menu-bar app (an NSStatusItem hosting the SwiftUI label — see
// Sources/TokenTab/Views/StatusItemController.swift) that reads ~/.claude/projects locally,
// makes no network calls, and renders the two-mode dropdown from the design. The trust story
// is OS-enforced: the shipped .app is App-Sandboxed with NO network entitlement and a
// security-scoped, read-only grant of ~/.claude (see Bundle/TokenTab.entitlements and
// Scripts/build-app.sh). `swift run TokenTab` is the fast dev path (unsandboxed, direct read);
// `Scripts/build-app.sh` produces the real sandboxed Token Tab.app.
//
// Pure model code (Core, Pricing) is a faithful port of ../src/core.mjs + pricing.mjs,
// so the numbers reconcile with the audited JS engine line-for-line. TokenTabCore is a
// separate library target so it can be unit-tested without the GUI.
let package = Package(
    name: "TokenTab",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TokenTabCore"),
        .executableTarget(
            name: "TokenTab",
            dependencies: ["TokenTabCore"],
            resources: [.copy("Resources/Fonts")]   // Martian Mono (OFL) — the hero numeric face
        ),
        // The live-% helper: the ONE subprocess in the native stack, deliberately fenced
        // OUTSIDE app/Sources (in app/Helper) so the audit greps over app/Sources stay
        // clean — the Swift twin of adapters/ vs src/ on the JS side. Ships inside the
        // .app at Contents/MacOS, launched by launchd via the bundled agent plist
        // (Bundle/com.tokentab.liveagent.plist), never as a child of the sandboxed app.
        .executableTarget(
            name: "TokenTabLiveHelper",
            dependencies: ["TokenTabCore"],
            path: "Helper",
            exclude: ["Info.plist"],
            // Embed Helper/Info.plist in the binary: the helper runs App-Sandboxed
            // (macOS ≥14.2 requires sandboxed agents from a sandboxed app), and the
            // sandbox keys a bare executable's container off the bundle identifier in
            // this embedded section — without it, libsecinit traps at launch.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate",
                              "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", "Helper/Info.plist"])
            ]
        ),
        .testTarget(
            name: "TokenTabCoreTests",
            dependencies: ["TokenTabCore"]
        ),
        .testTarget(
            name: "TokenTabAppTests",
            dependencies: ["TokenTab"]
        ),
    ]
)
