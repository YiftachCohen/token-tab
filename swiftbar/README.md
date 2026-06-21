# Token Tab: SwiftBar plugin

The fast on-ramp: get your token tab in the menu bar tonight, no app to build or sign.
(The native sandboxed app is the long-term keeper; see the root README. This path
trades the scoped-read trust story for speed: **SwiftBar itself may need Full Disk
Access** to read `~/.claude`, which is a broader grant than the native app asks for.)

## Install

1. Install [SwiftBar](https://github.com/swiftbar/SwiftBar): `brew install swiftbar`,
   launch it, and pick a plugin folder when prompted.
2. Symlink this plugin into that folder (symlink, so updates to the repo apply live):
   ```sh
   ln -s "$(pwd)/swiftbar/token-tab.30s.sh" \
     ~/Library/Application\ Support/SwiftBar/token-tab.30s.sh
   ```
   (Use your actual SwiftBar plugin folder if you chose a different one.)
3. Make sure it's executable: `chmod +x swiftbar/token-tab.30s.sh`
4. SwiftBar → **Refresh all**. You should see `◧ <today's tokens>` in the menu bar.

## Live server % (opt-in)

Want the authoritative session/weekly `%` (what `claude /usage` shows), not just the
local estimate? Install the live plugin instead of (or alongside) the default:
```sh
ln -s "$(pwd)/swiftbar/token-tab-live.2m.sh" \
  ~/Library/Application\ Support/SwiftBar/token-tab-live.2m.sh
```
It refreshes every 2 minutes (not 30s — `/usage` shouldn't be polled that often), sets
`TOKENTAB_LIVE=1`, and resolves the `claude` binary. It shells out to the official
`claude` CLI (which does the network/keychain); Token Tab only parses the output and
falls back to the local estimate on any failure. See "The live server %" in the root
README. If `claude` isn't auto-found, set `TOKENTAB_CLAUDE_BIN` to its absolute path.

## Requirements
- `node` (≥18) or `bun` on disk. The wrapper looks in Homebrew/system paths because
  SwiftBar runs with a minimal `PATH`.

## Troubleshooting
- **Nothing shows / blank:** SwiftBar may need **Full Disk Access** to read
  `~/.claude/projects`. System Settings → Privacy & Security → Full Disk Access → add
  SwiftBar. (This broad grant is exactly why the native app exists.)
- **"No node/bun found":** install Node (`brew install node`) or Bun.
- **Custom log location:** set `TOKENTAB_LOG_DIR` in the plugin's environment, or rely
  on `CLAUDE_CONFIG_DIR`.
- **Different refresh rate:** rename the symlink, e.g. `token-tab.1m.sh` for 1 minute.
