// Token Tab — security-scoped read access to ~/.claude.
//
// The shipped app is App-Sandboxed with NO network entitlement; the only way it can read
// ~/.claude is a user-granted, read-only security-scoped bookmark. This manager:
//   • resolves a saved bookmark on launch and re-acquires the scope,
//   • re-prompts cleanly when the bookmark is stale (folder moved / permission reset) —
//     the documented "#1 practical failure mode" for sandboxed file apps,
//   • falls back to a direct read when running UNSANDBOXED (`swift run` dev path), so the
//     app is runnable the instant you build it, before any grant flow.
//
// No content is ever read here — this only hands a directory URL to LogReader.

import Foundation
import AppKit

@MainActor
final class AccessManager: ObservableObject {
    enum State: Equatable {
        case resolving
        case granted(URL)        // sandboxed: bookmark resolved & scope acquired
        case directRead(URL)     // unsandboxed dev: read the default dir directly
        case needsGrant(URL)     // sandboxed first run / stale bookmark → prompt
    }

    @Published private(set) var state: State = .resolving
    private let defaultsKey = "claudeFolderBookmark"
    private var scopedURL: URL?

    // Codex (~/.codex) read access is the exact same mechanism as Claude's: a user-granted,
    // read-only security-scoped bookmark — NOT a broadened entitlement (the app stays
    // files.user-selected.read-only only, so no home-folder access). The launch path below
    // re-acquires a previously granted scope; the grant UI itself is a later phase, and
    // unsandboxed `swift run` reads ~/.codex directly with no scope needed.
    private let codexDefaultsKey = "codexFolderBookmark"
    private var codexScopedURL: URL?

    /// Published so the Settings grant row can reflect "granted" vs "grant needed" live. True
    /// once a ~/.codex scope is held (a saved bookmark resolved on launch, or a fresh grant).
    @Published private(set) var codexGranted = false

    /// The directory we should read, if any.
    var logDir: URL? {
        switch state {
        case .granted(let u), .directRead(let u): return u
        case .needsGrant, .resolving: return nil
        }
    }

    func bootstrap() {
        // Re-acquire a previously granted ~/.codex scope for the app's lifetime (held until exit,
        // like the Claude scope). No-op when none was ever granted — the Codex reader then finds no
        // files under the sandbox and is silently skipped, exactly the intended fail-soft.
        resolveCodexBookmark()
        let target = LogReader.defaultLogDir()
        // 1) Try a saved bookmark (the sandboxed happy path). Route it through the
        //    same projects-dir resolution as a fresh grant, so a relaunch reads the
        //    same directory the first run did.
        if let url = resolveSavedBookmark() {
            state = .granted(Self.resolveProjectsDir(under: url))
            return
        }
        // 2) Unsandboxed dev: if we can list the default dir directly, just use it.
        if FileManager.default.isReadableFile(atPath: target.path),
           (try? FileManager.default.contentsOfDirectory(atPath: target.path)) != nil {
            state = .directRead(target)
            return
        }
        // 3) Sandboxed first run (or stale) — need the user to grant access.
        state = .needsGrant(target)
    }

    /// Release the currently held security-scoped resource before acquiring a
    /// new scope. macOS holds a finite number of sandbox extensions per process;
    /// re-granting without releasing the old one leaks one each time. The launch
    /// scope is intentionally held for the app's lifetime (reclaimed at exit).
    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func resolveSavedBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { UserDefaults.standard.removeObject(forKey: defaultsKey); return nil }
        // Self-heal an over-broad grant saved by an earlier version (0.1.0 could
        // capture the whole home folder — see requestAccess): drop it and re-prompt
        // instead of walking folders this app should never touch.
        if Self.isOverBroadGrant(url) {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return nil
        }
        releaseScope() // self-consistent: never stack a second scope on an existing one
        guard url.startAccessingSecurityScopedResource() else { return nil }
        scopedURL = url
        return url
    }

    /// Resolve the saved ~/.codex bookmark (if any) and hold its scope for the app's lifetime.
    /// Mirrors resolveSavedBookmark; a stale bookmark is dropped (the phase-6 grant UI re-prompts).
    @discardableResult
    private func resolveCodexBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: codexDefaultsKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { UserDefaults.standard.removeObject(forKey: codexDefaultsKey); return nil }
        codexScopedURL?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else { return nil }
        codexScopedURL = url
        codexGranted = true
        return url
    }

    /// Open the folder picker for ~/.codex — the exact same read-only, security-scoped grant
    /// as Claude's, stored under `codexFolderBookmark`. Not a widened entitlement: the app
    /// stays `files.user-selected.read-only`, so this adds one folder, not home-folder access.
    /// Returns true when a scope was acquired, so the caller can kick a refresh.
    @discardableResult
    func requestCodexAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true      // ~/.codex is a dotfile, hidden by default
        panel.prompt = "Grant read access"
        panel.message = "Token Tab reads token counts from ~/.codex. Select the .codex folder."
        let codex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        panel.directoryURL = FileManager.default.fileExists(atPath: codex.path) ? codex : FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        codexScopedURL?.stopAccessingSecurityScopedResource()
        if let data = try? chosen.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: codexDefaultsKey)
        }
        guard chosen.startAccessingSecurityScopedResource() else { return false }
        codexScopedURL = chosen
        codexGranted = true
        return true
    }

    /// Open the folder picker, pre-pointed at ~/.claude with hidden files shown
    /// (Open Q#4 — ~/.claude is a dotfile that NSOpenPanel hides by default).
    func requestAccess() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Grant read access"
        panel.message = "Token Tab reads token counts from ~/.claude. Select the .claude folder (or its projects subfolder)."
        // Point the panel at ~/.claude UNCONDITIONALLY. The panel runs out-of-process
        // (powerbox) and can browse where this sandboxed app cannot even stat — a
        // fileExists() pre-check here is always false inside the sandbox, which would
        // silently drop the picker at the home folder instead.
        let claude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        panel.directoryURL = claude

        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // Refuse a grant of the home folder (or wider). One click on "Grant read
        // access" while the panel sits at ~ would hand over everything — and walking
        // it trips the OS consent prompts for Desktop / Documents / media library,
        // the exact opposite of this app's promise.
        if Self.isOverBroadGrant(chosen) {
            let alert = NSAlert()
            alert.messageText = "That folder is too broad"
            alert.informativeText = "Token Tab only reads Claude Code's logs. Select the .claude folder itself (or its projects subfolder) — not your home folder."
            alert.runModal()
            requestAccess()
            return
        }
        releaseScope() // drop any previously held scope before acquiring the new one
        if let data = try? chosen.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        _ = chosen.startAccessingSecurityScopedResource()
        scopedURL = chosen
        state = .granted(Self.resolveProjectsDir(under: chosen))
    }

    /// True when a grant would cover the whole home folder or an ancestor of it
    /// (`/`, `/Users`, …) — far more than this app should ever see, and enumerating
    /// it triggers the OS's Desktop / Documents / media-library consent prompts.
    nonisolated static func isOverBroadGrant(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let chosen = url.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        if chosen == "/" || chosen == homePath { return true }
        return (homePath + "/").hasPrefix(chosen + "/")
    }

    /// If the user picked `.claude` itself, descend to `projects` (where the logs live);
    /// if they picked `projects` directly, use it as-is.
    nonisolated static func resolveProjectsDir(under url: URL) -> URL {
        if url.lastPathComponent == "projects" { return url }
        let projects = url.appendingPathComponent("projects")
        return FileManager.default.fileExists(atPath: projects.path) ? projects : url
    }
}
