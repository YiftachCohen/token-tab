// Token Tab — app entry point.
//
// A MenuBarExtra agent (no Dock icon): the bar shows one glanceable glyph, the dropdown
// shows the breakdown. No network anywhere in this process — the only I/O is a read of
// the granted ~/.claude directory. The shipped build is App-Sandboxed with no network
// entitlement (see Bundle/TokenTab.entitlements); `swift run` is the unsandboxed dev path.

import SwiftUI

@main
struct TokenTabApp: App {
    @StateObject private var access: AccessManager
    @StateObject private var store: UsageStore
    @State private var started = false

    init() {
        Probe.runIfRequested()   // `--probe`: print the aggregate JSON and exit, no UI.
        // Make it a menu-bar-only agent even via `swift run` (no Info.plist there).
        NSApplication.shared.setActivationPolicy(.accessory)
        let access = AccessManager()
        _access = StateObject(wrappedValue: access)
        // The store reads whatever directory access currently exposes (bookmark or direct).
        _store = StateObject(wrappedValue: UsageStore(logDir: { [weak access] in access?.logDir }))
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView(store: store, access: access)
        } label: {
            MenuBarLabel(snapshot: store.snapshot, menuMetric: store.menuMetric)
                .onAppear { startup() }   // the label is present at launch → runs immediately
        }
        .menuBarExtraStyle(.window)
    }

    private func startup() {
        guard !started else { return }
        started = true
        access.bootstrap()
        store.start()   // timer no-ops harmlessly until access is granted
    }
}
