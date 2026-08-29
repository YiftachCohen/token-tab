// The dropdown must render in the SYSTEM's light/dark, not the menu bar's.
//
// An NSPopover anchored to a status item inherits its appearance from the STATUS BAR window,
// and that window is `vibrantDark` whenever the menu bar is light-on-dark — which, in Light
// Mode, it is over any dark desktop picture. Every `Theme.dynamic` color resolves against the
// view's effective appearance, so the whole panel came up in its dark palette (near-white ink
// on cool blue-greys) on a light-mode Mac. `togglePopover` pins the popover to the app's own
// effective appearance to break that inheritance; this test is what keeps that pin there.
//
// Two things it deliberately does NOT assert:
//   * the RESOLVED appearance of the presented panel. An NSPopover needs a real application
//     event loop to actually come up; inside an xctest process `show(relativeTo:)` leaves
//     `isShown == false` and the content view never gets a window, so its effectiveAppearance
//     would just report the app's — passing whether or not the pin is there. Verified against
//     the running app instead (dark menu bar + Aqua app → panel resolved vibrantDark before
//     the fix, Aqua after).
//   * the activation half of the same fix (`NSApp.activate` + `makeKey`, so the glass isn't
//     drawn in its flat inactive grey and the Settings cap field can take a keystroke).
//     Whether a process may take focus is the window server's call, so it would be an
//     environment check, not a code check.

import XCTest
import AppKit
import SwiftUI
@testable import TokenTab

@MainActor
final class StatusItemAppearanceTests: XCTestCase {
    func testDropdownIsPinnedToTheSystemAppearanceNotTheMenuBars() throws {
        // `NSApp` is nil until something asks for the shared application — an xctest process
        // has no `main()` that made one.
        let app = NSApplication.shared
        // Force the "Light Mode over a dark wallpaper" case regardless of how this Mac is set.
        let previous = app.appearance
        app.appearance = NSAppearance(named: .aqua)
        defer { app.appearance = previous }

        let controller = StatusItemController(
            store: UsageStore(logDir: { nil }, codexDir: { nil }),   // never started: no reads
            access: AccessManager(),
            helper: LiveHelperManager())
        controller.install()
        defer {
            controller.popover?.performClose(nil)
            if let item = controller.statusItem { NSStatusBar.system.removeStatusItem(item) }
        }
        try XCTSkipIf(controller.statusItem?.button == nil,
                      "no window server session to put a status item in")

        controller.togglePopover()

        let pinned = try XCTUnwrap(controller.popover?.appearance,
                                   "the dropdown must pin its own appearance — left unset it "
                                   + "inherits the vibrantDark status-bar window it hangs from")
        XCTAssertEqual(pinned.bestMatch(from: [.aqua, .darkAqua]), .aqua,
                       "the pin must follow the system appearance Theme colors resolve against")
    }
}
