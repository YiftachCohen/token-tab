// Token Tab — TokenTabLiveHelper: the bundled live-usage writer.
//
// The Swift twin of adapters/write-live.mjs + claude-live.mjs, compiled into the .app
// at Contents/MacOS/TokenTabLiveHelper. It is the ONE subprocess in the native stack,
// deliberately fenced OUTSIDE app/Sources (this dir, app/Helper) so the audit greps
// over app/Sources keep printing nothing.
//
// What it does — the whole job, nothing else:
//   1. run the official `claude -p "/usage" --output-format json` (claude does the
//      keychain read and the network call; this process only reads its stdout),
//   2. parse the percentages (TokenTabCore.LiveParse — pure, shared with the app),
//   3. atomically write <logDir>/.token-tab-live.json for the sandboxed app to read.
//
// It is NEVER spawned by the app (the sandbox can't). launchd runs it on a timer via
// the bundled agent plist (Bundle/com.tokentab.liveagent.plist), which the user turns
// on with the in-app "Live %" toggle (SMAppService) — visible and revocable in
// System Settings ▸ Login Items. Fails closed: on any problem it writes nothing,
// logs one line to ~/Library/Logs/token-tab-live.log, and exits non-zero.

import Foundation
import TokenTabCore

let fm = FileManager.default
/// The REAL home, from the passwd db — not $HOME. This helper runs App-Sandboxed
/// (macOS ≥14.2 requires it: a sandboxed app may only register sandboxed agents), and
/// inside the sandbox $HOME points at the container. Everything claude-related lives
/// under the real home, reachable via the temporary-exception entitlements.
let home: URL = {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return fm.homeDirectoryForCurrentUser
}()
let env = ProcessInfo.processInfo.environment

// MARK: - config (env wins, then the same dotfiles the app and JS engine honor)

let fileValues: [String: String] = {
    var candidates: [URL] = []
    if let cfg = env["TOKENTAB_CONFIG"], !cfg.isEmpty {
        candidates.append(URL(fileURLWithPath: (cfg as NSString).expandingTildeInPath))
    }
    candidates.append(home.appendingPathComponent(".config/token-tab/env"))
    candidates.append(home.appendingPathComponent(".token-tab.env"))
    var values: [String: String] = [:]
    for url in candidates {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for (key, val) in EnvFile.parse(text) where values[key] == nil { values[key] = val }
    }
    return values
}()

func setting(_ key: String) -> String? {
    if let v = env[key], !v.isEmpty { return v }
    if let v = fileValues[key], !v.isEmpty { return v }
    return nil
}

/// Tilde-expand against the REAL home (expandingTildeInPath would use the container's).
func expand(_ path: String) -> String {
    if path == "~" { return home.path }
    if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
    return path
}

// MARK: - logging (one line per run; the file self-trims so it can never grow unbounded)

let logURL = home.appendingPathComponent("Library/Logs/token-tab-live.log")
let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("[token-tab live] \(message)\n".utf8))
    let line = "\(iso.string(from: Date())) \(message)\n"
    if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 64 * 1024 {
        try? fm.removeItem(at: logURL)
    }
    if let handle = FileHandle(forWritingAtPath: logURL.path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: Data(line.utf8))
    }
}

// MARK: - resolve the cache path (mirrors liveCachePath in adapters/write-live.mjs)

func cacheURL() -> URL {
    let file = ".token-tab-live.json"
    if let p = setting("TOKENTAB_LIVE_CACHE") { return URL(fileURLWithPath: expand(p)) }
    if let d = setting("TOKENTAB_LOG_DIR") {
        return URL(fileURLWithPath: expand(d)).appendingPathComponent(file)
    }
    if let c = env["CLAUDE_CONFIG_DIR"], !c.isEmpty {
        return URL(fileURLWithPath: expand(c)).appendingPathComponent("projects").appendingPathComponent(file)
    }
    return home.appendingPathComponent(".claude/projects").appendingPathComponent(file)
}

// MARK: - resolve claude (mirrors resolveClaude in adapters/claude-live.mjs)

func resolveClaude() -> URL? {
    if let bin = setting("TOKENTAB_CLAUDE_BIN") { return URL(fileURLWithPath: expand(bin)) }
    var candidates = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        home.appendingPathComponent(".claude/local/claude").path,
        home.appendingPathComponent(".local/bin/claude").path,
        home.appendingPathComponent(".bun/bin/claude").path,
    ]
    // Last resort: walk PATH (the agent plist sets a sane one for launchd).
    for dir in (env["PATH"] ?? "").split(separator: ":") {
        candidates.append("\(dir)/claude")
    }
    for c in candidates where fm.isExecutableFile(atPath: c) {
        return URL(fileURLWithPath: c)
    }
    return nil
}

// MARK: - run `claude -p "/usage" --output-format json`

/// Spawn claude and return its stdout, or nil on spawn failure / timeout / non-zero exit.
/// cwd is a fresh temp dir, NOT $HOME: `claude -p` roots a session at its working
/// directory and indexes it; under launchd the cwd is $HOME, so it would walk into
/// ~/Desktop / ~/Documents and trip macOS's TCC consent prompts. /usage reads the server
/// quota, never local files — an empty tmpdir gives it nothing to scan.
func runClaudeUsage(bin: URL, timeout: TimeInterval = 60) -> String? {
    let tmp = fm.temporaryDirectory.appendingPathComponent("token-tab-live-\(getpid())", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    let proc = Process()
    proc.executableURL = bin
    proc.arguments = ["-p", "/usage", "--output-format", "json"]
    proc.currentDirectoryURL = tmp
    // The child inherits this sandbox AND its container-pointing $HOME. claude keeps its
    // config, credentials and state under the real ~/.claude (which the entitlements
    // open), so hand it the real home explicitly.
    var childEnv = env
    childEnv["HOME"] = home.path
    proc.environment = childEnv
    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = FileHandle.nullDevice
    proc.standardInput = FileHandle.nullDevice   // never block waiting on stdin
    do { try proc.run() } catch {
        log("spawn failed: \(error.localizedDescription)")
        return nil
    }

    // Watchdog: SIGTERM past the deadline. Terminating also closes the pipe, so the
    // read below can never hang forever.
    let timeoutState = TimeoutState()
    let watchdog = DispatchWorkItem {
        if proc.isRunning {
            timeoutState.markTimedOut()
            proc.terminate()
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

    // Drain stdout BEFORE waitUntilExit (a full pipe buffer would deadlock the child).
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    watchdog.cancel()

    guard proc.terminationStatus == 0 else {
        log(timeoutState.didTimeOut
            ? "claude timed out after \(Int(timeout))s"
            : "claude exited \(proc.terminationStatus)")
        return nil
    }
    return String(data: data.prefix(256 * 1024), encoding: .utf8)
}

/// `Process.terminate()` can make a CLI wrapper report exit 143 instead of an uncaught
/// signal. Keep the watchdog's cause so the log distinguishes our bounded timeout from a
/// real Claude failure.
final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
    }

    var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}

// MARK: - serialize + atomic write (mirrors serializeLive / writeLiveCache)

/// Shape a parsed reading into the on-disk JSON (schema 1, same shape write-live.mjs
/// writes and LiveReader reads). Percent fields are explicit nulls, not omitted, so the
/// JSON stays stable. Returns nil when there is nothing worth writing.
func serialize(_ reading: LiveParse.Reading, capturedAt: Date) -> Data? {
    guard reading.sessionPct != nil || reading.weeklyPct != nil else { return nil }
    let obj: [String: Any] = [
        "schema": 1,
        "source": "claude /usage",
        "capturedAt": iso.string(from: capturedAt),
        "sessionPct": reading.sessionPct.map { $0 as Any } ?? NSNull(),
        "sessionResetText": reading.sessionResetText.map { $0 as Any } ?? NSNull(),
        "weeklyPct": reading.weeklyPct.map { $0 as Any } ?? NSNull(),
        "weeklyResetText": reading.weeklyResetText.map { $0 as Any } ?? NSNull(),
        "weeklyByModel": reading.weeklyByModel,
    ]
    return try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
}

/// 0600 tmp file + rename(2) — the app never sees a half-written cache.
func writeAtomically(_ data: Data, to url: URL) -> Bool {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = url.path + ".tmp"
    guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
    return rename(tmp, url.path) == 0
}

// MARK: - main

guard let bin = resolveClaude() else {
    log("claude not found — set TOKENTAB_CLAUDE_BIN in ~/.config/token-tab/env")
    exit(1)
}
guard let output = runClaudeUsage(bin: bin) else {
    exit(1)   // runClaudeUsage already logged the reason
}
guard let reading = LiveParse.parseUsageOutput(output),
      let json = serialize(reading, capturedAt: Date()) else {
    log("parse miss — `claude /usage` output not recognized; wrote nothing")
    exit(1)
}
let target = cacheURL()
guard writeAtomically(json, to: target) else {
    log("write failed: \(target.path)")
    exit(1)
}
log("wrote \(target.path)")
