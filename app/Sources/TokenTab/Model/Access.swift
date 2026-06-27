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

    /// The directory we should read, if any.
    var logDir: URL? {
        switch state {
        case .granted(let u), .directRead(let u): return u
        case .needsGrant, .resolving: return nil
        }
    }

    func bootstrap() {
        let target = LogReader.defaultLogDir()
        // 1) Try a saved bookmark (the sandboxed happy path).
        if let url = resolveSavedBookmark() {
            state = .granted(url)
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
        releaseScope() // self-consistent: never stack a second scope on an existing one
        guard url.startAccessingSecurityScopedResource() else { return nil }
        scopedURL = url
        return url
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
        let claude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        panel.directoryURL = FileManager.default.fileExists(atPath: claude.path) ? claude : FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        releaseScope() // drop any previously held scope before acquiring the new one
        if let data = try? chosen.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        _ = chosen.startAccessingSecurityScopedResource()
        scopedURL = chosen
        state = .granted(resolveProjectsDir(under: chosen))
    }

    /// If the user picked `.claude` itself, descend to `projects` (where the logs live);
    /// if they picked `projects` directly, use it as-is.
    private func resolveProjectsDir(under url: URL) -> URL {
        if url.lastPathComponent == "projects" { return url }
        let projects = url.appendingPathComponent("projects")
        return FileManager.default.fileExists(atPath: projects.path) ? projects : url
    }
}
