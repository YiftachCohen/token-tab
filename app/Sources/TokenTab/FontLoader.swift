// Token Tab — register the bundled hero numeric face (Martian Mono) at launch.
//
// The hero figures (the gauge %, the burn $, the History totals, the runway time) use
// Martian Mono so a number reads as a *measurement*, not the OS. The font is bundled (OFL,
// see Resources/Fonts/OFL.txt) and registered into THIS PROCESS only — no network, no
// install, nothing added to Font Book. If registration ever fails, `Font.custom` falls back
// to the system face, so the UI degrades gracefully instead of breaking.

import Foundation
import CoreText

enum FontLoader {
    private static var registered = false

    /// Register the bundled Martian Mono so `Theme.hero` (and `Font.custom("Martian Mono", …)`)
    /// resolves. Idempotent and silent: a repeat call, a missing resource, or an already-
    /// registered font all no-op rather than raising.
    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        // .app (sandboxed/release): the font ships under Contents/Resources/Fonts via
        // build-app.sh, found through Bundle.main. `swift run` (dev): SwiftPM's Bundle.module
        // resource bundle. Try both so dev and shipped builds both resolve it.
        let url = Bundle.main.url(forResource: "MartianMono", withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: "MartianMono", withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: "MartianMono", withExtension: "ttf")
        guard let url else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
