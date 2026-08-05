// Token Tab — the shot runner.
//
//     TOKENTAB_SHOTS=1 swift test --package-path app --filter ShotsTests
//
// Writes docs/screenshots/generated/*.png. It lives in the test target because that is the
// only place `@testable import TokenTab` reaches the views and their model types — but it is
// NOT a test: it asserts nothing about behavior, so it skips unless TOKENTAB_SHOTS=1 and
// leaves CI (and `swift test`) exactly as it was.
//
// Every image is staged from ShotFixtures, never from the machine's own ~/.claude — see the
// note there on why a real snapshot must never become a marketing asset.

import XCTest
import SwiftUI
import AppKit
@testable import TokenTab
@testable import TokenTabCore

@MainActor
final class ShotsTests: XCTestCase {

    func testRenderShots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOKENTAB_SHOTS"] == "1",
                          "shot renderer — run with TOKENTAB_SHOTS=1")
        FontLoader.registerBundledFonts()

        let outDir = Self.repoRoot.appendingPathComponent("docs/screenshots/generated")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for scene in Self.scenes() {
            guard let rep = ShotStage.render(scene) else {
                XCTFail("failed to render \(scene.name)"); continue
            }
            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("failed to encode \(scene.name)"); continue
            }
            let url = outDir.appendingPathComponent("\(scene.name).png")
            try png.write(to: url)
            print("shot: \(scene.name).png  \(rep.pixelsWide)×\(rep.pixelsHigh)px")
        }
        print("shots written to \(outDir.path)")
    }

    // MARK: - The scene list

    /// One entry per image. Ordered hero-first, because that is the order a README wants them.
    private static func scenes() -> [ShotStage.Scene] {
        let now = Date()
        let subscription = ShotFixtures.subscription(now: now)
        let burn = ShotFixtures.burn(now: now)
        let dual = ShotFixtures.dualProvider(now: now)

        return [
            // The hero: Claude Max runway, glass over a desktop, live reading.
            .init(name: "hero-subscription-dark", snapshot: subscription, scheme: .dark),
            .init(name: "hero-subscription-light", snapshot: subscription, scheme: .light),

            // Pay-per-token — the amber half of the color-as-mode rule.
            .init(name: "burn-bedrock-dark", snapshot: burn, scheme: .dark, menuMetric: .cost),

            // Both providers: Codex focused (indigo hero) with Claude as the secondary row.
            .init(name: "codex-dual-dark", snapshot: dual, scheme: .dark, focus: .codex),

            // History, on both modes — the bars are green on subscription, amber on burn.
            .init(name: "history-subscription-dark", snapshot: subscription, scheme: .dark,
                  tab: .history, bottomPad: 56),
            .init(name: "history-burn-dark", snapshot: burn, scheme: .dark,
                  tab: .history, bottomPad: 56),

            // NOTE — no Settings scene, deliberately. SettingsView reads the live environment
            // rather than the Snapshot, so a shot of it in a test process is captioned with
            // that process's truths: "~/.codex not found", "No bundled helper in this build
            // (dev run)", and whatever cap the local env/dotfile sets. Staging it honestly
            // means faking AccessManager.codexState, LiveHelperManager.status and the cap
            // source too — worth doing if a Settings image is needed, but shipping the dev-run
            // version would put a screenshot of a broken install on the README.
            // `DropdownView(initialSettings: true)` already works; only the data is missing.

            // Documentation variants: same real views on a flat ground, no wallpaper to
            // fight the text in a README.
            .init(name: "plate-subscription-dark", snapshot: subscription, scheme: .dark,
                  ground: .plate),
            .init(name: "plate-subscription-light", snapshot: subscription, scheme: .light,
                  ground: .plate),
            .init(name: "plate-burn-light", snapshot: burn, scheme: .light, ground: .plate),
        ]
    }

    /// The repo root, resolved from this file rather than the working directory — `swift test`
    /// can be invoked from anywhere, and silently writing shots into the wrong tree is worse
    /// than failing.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // app/Tests/TokenTabAppTests/Shots/ShotsTests.swift
            .deletingLastPathComponent()          // Shots
            .deletingLastPathComponent()          // TokenTabAppTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // app
            .deletingLastPathComponent()          // repo root
    }
}
