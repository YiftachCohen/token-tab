// swift-tools-version:5.9
import PackageDescription

// Token Tab — native macOS menu-bar app (Approach A, the "keeper").
//
// A SwiftUI MenuBarExtra app that reads ~/.claude/projects locally, makes no network
// calls, and renders the two-mode dropdown from the design. The trust story is
// OS-enforced: the shipped .app is App-Sandboxed with NO network entitlement and a
// security-scoped, read-only grant of ~/.claude (see Bundle/TokenTab.entitlements and
// Scripts/build-app.sh). `swift run` is the fast dev path (unsandboxed, direct read);
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
            dependencies: ["TokenTabCore"]
        ),
        .testTarget(
            name: "TokenTabCoreTests",
            dependencies: ["TokenTabCore"]
        ),
    ]
)
