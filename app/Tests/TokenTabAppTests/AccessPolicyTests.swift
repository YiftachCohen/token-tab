// Token Tab — grant-scope policy tests.
//
// Pins the two pure decisions behind the security-scoped grant flow:
//   • isOverBroadGrant — the whole home folder (or an ancestor) must be refused,
//     because walking it trips the OS's Desktop / media-library consent prompts
//     (the v0.1.0 first-run bug: the sandboxed picker opened at ~, one click
//     granted $HOME, and the walker crawled it).
//   • resolveProjectsDir — picking `.claude` descends to `projects`; picking
//     `projects` (or any leaf dir) is used as-is.

import XCTest
@testable import TokenTab

final class AccessPolicyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    // MARK: isOverBroadGrant

    func testHomeFolderItselfIsRefused() {
        XCTAssertTrue(AccessManager.isOverBroadGrant(URL(fileURLWithPath: "/Users/dev"), home: home))
    }

    func testTrailingSlashStillRefused() {
        XCTAssertTrue(AccessManager.isOverBroadGrant(URL(fileURLWithPath: "/Users/dev/"), home: home))
    }

    func testAncestorsOfHomeAreRefused() {
        XCTAssertTrue(AccessManager.isOverBroadGrant(URL(fileURLWithPath: "/"), home: home))
        XCTAssertTrue(AccessManager.isOverBroadGrant(URL(fileURLWithPath: "/Users"), home: home))
    }

    func testClaudeFolderIsAllowed() {
        XCTAssertFalse(AccessManager.isOverBroadGrant(URL(fileURLWithPath: "/Users/dev/.claude"), home: home))
    }

    func testProjectsSubfolderIsAllowed() {
        XCTAssertFalse(AccessManager.isOverBroadGrant(URL(fileURLWithPath: "/Users/dev/.claude/projects"), home: home))
    }

    /// "/Users/devops" shares a string prefix with "/Users/dev" but is NOT an
    /// ancestor — the check must compare path components, not raw prefixes.
    func testSiblingWithSharedPrefixIsAllowed() {
        XCTAssertFalse(AccessManager.isOverBroadGrant(URL(fileURLWithPath: "/Users/devops"), home: home))
    }

    /// A custom log dir on another volume (TOKENTAB_LOG_DIR) is a deliberate,
    /// narrow choice — allowed.
    func testUnrelatedVolumeIsAllowed() {
        XCTAssertFalse(AccessManager.isOverBroadGrant(URL(fileURLWithPath: "/Volumes/Work/claude-logs"), home: home))
    }

    // MARK: resolveProjectsDir

    func testClaudeDirDescendsToProjects() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent(".claude")
        let projects = claude.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        XCTAssertEqual(AccessManager.resolveProjectsDir(under: claude).lastPathComponent, "projects")
    }

    func testProjectsDirUsedAsIs() {
        let projects = URL(fileURLWithPath: "/anywhere/projects")
        XCTAssertEqual(AccessManager.resolveProjectsDir(under: projects), projects)
    }

    func testDirWithoutProjectsUsedAsIs() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(AccessManager.resolveProjectsDir(under: root), root)
    }

    // MARK: resolveCodexRoot

    /// Picking ~/.codex itself is the happy path — the reader walks sessions/** under it.
    func testCodexRootUsedAsIs() {
        let root = URL(fileURLWithPath: "/Users/dev/.codex")
        XCTAssertEqual(AccessManager.resolveCodexRoot(under: root), root)
    }

    /// Drilling one folder deeper in the picker still grants a usable scope: the reader looks
    /// for `sessions` UNDER the root, so a `sessions` grant has to climb back up.
    func testCodexSessionsDirClimbsToRoot() {
        XCTAssertEqual(AccessManager.resolveCodexRoot(under: URL(fileURLWithPath: "/Users/dev/.codex/sessions")).path,
                       "/Users/dev/.codex")
        XCTAssertEqual(AccessManager.resolveCodexRoot(under: URL(fileURLWithPath: "/Users/dev/.codex/archived_sessions")).path,
                       "/Users/dev/.codex")
    }

    // MARK: codexState
    //
    // The 0.3.0 regression: an invisible ~/.codex was reported as "not found", and the grant
    // button was gated on the same unobservable check — so a sandboxed Codex user could never
    // reach the picker. Not-listable must resolve to `.needsGrant`, never to a silent no-op.

    func testUnlistableCodexRootAsksForAGrantRatherThanClaimingItIsMissing() {
        let root = URL(fileURLWithPath: "/Users/dev/.codex")
        XCTAssertEqual(AccessManager.codexState(bookmarked: nil, root: root, rootListable: false),
                       .needsGrant(root))
    }

    func testListableCodexRootIsReadDirectly() {
        let root = URL(fileURLWithPath: "/Users/dev/.codex")
        XCTAssertEqual(AccessManager.codexState(bookmarked: nil, root: root, rootListable: true),
                       .directRead(root))
    }

    /// A resolved bookmark wins over the default root — the granted scope IS the dir we read.
    func testBookmarkWinsOverDefaultRoot() {
        let granted = URL(fileURLWithPath: "/Volumes/Work/.codex")
        XCTAssertEqual(AccessManager.codexState(bookmarked: granted,
                                                root: URL(fileURLWithPath: "/Users/dev/.codex"),
                                                rootListable: true),
                       .granted(granted))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("access-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
