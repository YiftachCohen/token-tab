// Token Tab — app entry point.
//
// A menu-bar agent (no Dock icon): the bar shows one glanceable glyph per provider, the
// dropdown shows the breakdown. No network anywhere in this process — the only I/O is a read
// of the granted ~/.claude directory. The shipped build is App-Sandboxed with no network
// entitlement (see Bundle/TokenTab.entitlements); `swift run TokenTab` is the unsandboxed
// dev path.
//
// The status item is owned by StatusItemController rather than declared as a SwiftUI
// MenuBarExtra scene — see that file for why (MenuBarExtra renders only one Text + one Image
// in its label, which truncated the two-provider label). This App therefore has no real
// scene: `Settings` is an empty placeholder because `App.body` must return one, and an
// accessory app never shows it.

import SwiftUI
import AppKit

@main
struct TokenTabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Probe.runIfRequested()   // `--probe`: print the aggregate JSON and exit, no UI.
        FontLoader.registerBundledFonts()   // hero figures use bundled Martian Mono (Theme.hero)
        // Make it a menu-bar-only agent even via `swift run` (no Info.plist there).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Owns the app's long-lived model objects and the status item. These used to be `@StateObject`s
/// on the App struct, held alive by the MenuBarExtra scene; with no scene to hold them, the
/// delegate is their home.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let access = AccessManager()
    /// The one-click switch for the bundled live-% helper (SMAppService / Login Items).
    private let helper = LiveHelperManager()
    private lazy var store = UsageStore(logDir: { [weak self] in self?.access.logDir },
                                        codexDir: { [weak self] in self?.access.codexLogDir })
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(store: store, access: access, helper: helper)
        controller.install()
        statusItem = controller
        access.bootstrap()
        store.start()   // timer no-ops harmlessly until access is granted
    }
}
