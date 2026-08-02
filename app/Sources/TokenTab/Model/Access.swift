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

    /// Same three states for ~/.codex, minus `resolving` (it is settled synchronously in
    /// `bootstrap()`, before any view reads it).
    enum CodexState: Equatable {
        case granted(URL)
        case directRead(URL)
        case needsGrant(URL)
    }

    @Published private(set) var state: State = .resolving
    private let defaultsKey = "claudeFolderBookmark"
    private var scopedURL: URL?

    // Codex (~/.codex) read access is the exact same mechanism as Claude's: a user-granted,
    // read-only security-scoped bookmark — NOT a broadened entitlement (the app stays
    // files.user-selected.read-only only, so no home-folder access). The launch path below
    // re-acquires a previously granted scope; unsandboxed `swift run` reads ~/.codex directly
    // with no scope needed.
    private let codexDefaultsKey = "codexFolderBookmark"
    private var codexScopedURL: URL?

    /// Codex access, resolved exactly like Claude's `State`. Published so the Settings row can
    /// show "granted" vs "grant needed" — and, crucially, so the grant button is offered from a
    /// state the SANDBOX can actually observe. A `fileExists(~/.codex)` probe is always false
    /// without a scope, so gating the button on "the folder exists" made the grant unreachable:
    /// no grant → looks missing → no button → no grant. (Shipped that way in 0.3.0.)
    @Published private(set) var codexState: CodexState = .needsGrant(CodexLogReader.defaultCodexRoot())

    /// True once a ~/.codex scope is held (a saved bookmark resolved on launch, or a fresh grant).
    var codexGranted: Bool { if case .granted = codexState { return true }; return false }

    /// The Codex root to read, if any — the granted scope, or the default dir when unsandboxed.
    var codexLogDir: URL? {
        switch codexState {
        case .granted(let u), .directRead(let u): return u
        case .needsGrant: return nil
        }
    }

    /// Whether the Settings row should offer the grant. The only honest signal in the sandbox:
    /// we cannot tell "no ~/.codex" from "no permission to look", so we offer the picker and
    /// let the user answer it.
    var codexNeedsGrant: Bool { if case .needsGrant = codexState { return true }; return false }

    /// The directory we should read, if any.
    var logDir: URL? {
        switch state {
        case .granted(let u), .directRead(let u): return u
        case .needsGrant, .resolving: return nil
        }
    }

    func bootstrap() {
        resolveCodexAccess()
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

    /// Settle `codexState` at launch, mirroring `bootstrap()`'s three-way resolution for Claude:
    /// a saved bookmark (re-acquired for the app's lifetime), else a direct read when the default
    /// root is listable (unsandboxed dev), else "ask the user". Note the sandboxed case cannot
    /// distinguish "~/.codex is absent" from "~/.codex is invisible to me" — both land on
    /// `.needsGrant`, which is why the UI must offer the picker rather than claim "not found".
    private func resolveCodexAccess() {
        let root = CodexLogReader.defaultCodexRoot()
        codexState = Self.codexState(
            bookmarked: resolveCodexBookmark(),
            root: root,
            rootListable: (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil
        )
    }

    /// The resolution itself, as a pure decision so it can be pinned by a test.
    nonisolated static func codexState(bookmarked: URL?, root: URL, rootListable: Bool) -> CodexState {
        if let url = bookmarked { return .granted(url) }
        if rootListable { return .directRead(root) }
        return .needsGrant(root)
    }

    /// Resolve the saved ~/.codex bookmark (if any) and hold its scope for the app's lifetime.
    /// Mirrors resolveSavedBookmark exactly, including the over-broad self-heal: a saved
    /// home-folder bookmark is dropped rather than re-opened, so a grant that slipped through
    /// an earlier build can't keep handing this app the whole home directory.
    @discardableResult
    private func resolveCodexBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: codexDefaultsKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { UserDefaults.standard.removeObject(forKey: codexDefaultsKey); return nil }
        if Self.isOverBroadGrant(url) {
            UserDefaults.standard.removeObject(forKey: codexDefaultsKey)
            return nil
        }
        codexScopedURL?.stopAccessingSecurityScopedResource()
        codexScopedURL = nil
        guard url.startAccessingSecurityScopedResource() else { return nil }
        codexScopedURL = url
        return Self.resolveCodexRoot(under: url)
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
        // Point the panel at ~/.codex UNCONDITIONALLY, for the same reason as the Claude
        // panel: powerbox runs out-of-process and can browse where this sandboxed app
        // cannot even stat, so a fileExists() pre-check is always false in the sandbox and
        // would silently drop the picker at the home folder — one click from granting it.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")

        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        // Refuse a home-folder (or wider) grant, exactly as the Claude picker does. Codex's
        // grant is the same read-only security-scoped mechanism, so it needs the same floor.
        if Self.isOverBroadGrant(chosen) {
            let alert = NSAlert()
            alert.messageText = "That folder is too broad"
            alert.informativeText = "Token Tab only reads Codex's logs. Select the .codex folder itself — not your home folder."
            alert.runModal()
            return requestCodexAccess()
        }
        codexScopedURL?.stopAccessingSecurityScopedResource()
        codexScopedURL = nil
        if let data = try? chosen.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: codexDefaultsKey)
        }
        guard chosen.startAccessingSecurityScopedResource() else { return false }
        codexScopedURL = chosen
        codexState = .granted(Self.resolveCodexRoot(under: chosen))
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

    /// The mirror of `resolveProjectsDir` for Codex, in the opposite direction: the reader walks
    /// `sessions/` and `archived_sessions/` UNDER the root, so a user who opens the picker at
    /// ~/.codex and drills one folder deeper (an easy click — `sessions` is the obvious target)
    /// would otherwise grant a scope the reader looks straight past. Climb back to the root.
    nonisolated static func resolveCodexRoot(under url: URL) -> URL {
        let leaf = url.lastPathComponent
        if leaf == "sessions" || leaf == "archived_sessions" { return url.deletingLastPathComponent() }
        return url
    }

    /// If the user picked `.claude` itself, descend to `projects` (where the logs live);
    /// if they picked `projects` directly, use it as-is.
    nonisolated static func resolveProjectsDir(under url: URL) -> URL {
        if url.lastPathComponent == "projects" { return url }
        let projects = url.appendingPathComponent("projects")
        return FileManager.default.fileExists(atPath: projects.path) ? projects : url
    }
}
