// Token Tab — the one-click switch for the bundled live-% helper.
//
// Wraps SMAppService for the LaunchAgent shipped inside the bundle
// (Contents/Library/LaunchAgents/com.tokentab.liveagent.plist → Contents/MacOS/
// TokenTabLiveHelper). Registering it is allowed from the sandbox because the helper is
// ALSO sandboxed (macOS ≥14.2 refuses otherwise — an unsandboxed agent would be a
// sandbox escape) and the app never runs it — launchd does, as its own process — with
// macOS surfacing the whole thing in System Settings ▸ Login Items, where the user can
// see it and kill it. This is what turns "clone the repo, install node, paste a script
// into Terminal" into one click.
//
// The app's trust posture is unchanged: this file only asks launchd to schedule or
// unschedule a job. No network, no subprocess, no file writes.

import Foundation
import ServiceManagement

@MainActor
final class LiveHelperManager: ObservableObject {
    /// The helper's user-facing state. `unavailable` = no agent plist in the bundle
    /// (the `swift run` dev path, or a bare binary) — the UI falls back to the manual
    /// script instructions instead of showing a toggle that could never work.
    enum Status: Equatable {
        case unavailable
        case off
        case on
        case requiresApproval   // registered, but the user must approve it in Login Items
    }

    @Published private(set) var status: Status = .unavailable
    @Published private(set) var lastError: String?

    nonisolated static let plistName = "com.tokentab.liveagent.plist"

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    /// The bundled agent plist, present only in a real .app assembled by build-app.sh.
    private var hasBundledAgent: Bool {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(Self.plistName)
        return FileManager.default.fileExists(atPath: plist.path)
    }

    /// Re-read launchd's view. Cheap; called when the dropdown opens so the status can
    /// never go stale behind a System Settings change.
    func refresh() {
        guard hasBundledAgent else { status = .unavailable; return }
        switch service.status {
        case .enabled:          status = .on
        case .requiresApproval: status = .requiresApproval
        case .notRegistered:    status = .off
        // .notFound despite the plist being in the bundle (checked above) means
        // SMAppService resolved a DIFFERENT copy of this bundle id — LaunchServices
        // keeps one canonical registration per id, and a second install (e.g. a dev
        // build next to /Applications) can shadow this one. register() registers THIS
        // copy and heals it, so offer the toggle; a real failure surfaces as lastError.
        case .notFound:         status = .off
        @unknown default:       status = .off
        }
    }

    /// Re-bind an already-enabled registration to THIS copy of the app. Called once at
    /// launch.
    ///
    /// launchd's record names a specific bundle, not a bundle id. Install a new version
    /// and drag the old copy to the Trash and the record goes on naming the binned one —
    /// and macOS will not execute code that lives in the Trash (the very same bundle runs
    /// fine from anywhere else; it's the location, not the signature, which still verifies
    /// and staples). So launchd retries the helper every StartInterval, is refused every
    /// time, and macOS puts up "Token Tab Not Opened … Move to Trash" on a five-minute
    /// loop. That dialog's button cannot help — the copy is already in the Trash — and
    /// `status` still reads `.enabled` here, so nothing in the UI ties the nag back to us.
    ///
    /// register() re-points the record at the running copy, so healing that is just
    /// registering again. Guarded on `.enabled`, so it can never switch the helper back on
    /// for someone who turned it off in Login Items.
    func healRegistration() {
        guard hasBundledAgent, service.status == .enabled else { return }
        try? service.register()
        refresh()
    }

    /// Register / unregister the agent. On success launchd starts the helper right away
    /// (RunAtLoad), the first cache write lands in the granted folder within seconds, and
    /// the FSEvents watcher picks it up — no extra plumbing needed here.
    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            // register() throwing with requiresApproval pending is normal — refresh()
            // below turns that into the "approve in Login Items" state, not an error.
            if service.status != .requiresApproval { lastError = error.localizedDescription }
        }
        refresh()
    }

    /// Deep-link to System Settings ▸ Login Items for the approval case.
    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
