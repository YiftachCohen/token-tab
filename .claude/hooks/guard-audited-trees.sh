#!/usr/bin/env bash
# Token Tab — post-edit guard (Claude Code PostToolUse hook; wired in .claude/settings.json).
#
# The moment an edit lands in an audited tree, re-run the same checks CI would fail on —
# the trust-invariant audit (AGENTS.md) and the design-token lint (DESIGN.md) — so the
# agent hears about a violation at edit time, not minutes later on the PR. Both checks
# are greps; the whole hook costs well under a second.
#
# Exit 2 feeds stderr back to the agent as feedback. Anything else is a silent pass —
# edits outside the audited trees exit 0 immediately.
set -u
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# The hook payload arrives as JSON on stdin; all we need is the edited file's path.
file="$(node -e '
let s = "";
process.stdin.on("data", (d) => (s += d)).on("end", () => {
  try { process.stdout.write(JSON.parse(s).tool_input?.file_path ?? ""); } catch {}
});' 2>/dev/null)"
[ -n "$file" ] || exit 0
rel="${file#"$PWD"/}"

case "$rel" in
  src/* | app/Sources/* | package.json) ;; # the trees trust-audit.sh covers
  *) exit 0 ;;
esac

trust_out="$(bash .github/scripts/trust-audit.sh 2>&1)"
trust=$?

design=0 design_out=""
case "$rel" in
  app/Sources/TokenTab/*)
    design_out="$(bash .github/scripts/design-lint.sh 2>&1)"
    design=$?
    ;;
esac

if [ "$trust" -ne 0 ] || [ "$design" -ne 0 ]; then
  {
    [ "$trust" -ne 0 ] && printf '%s\n' "$trust_out"
    [ "$design" -ne 0 ] && printf '%s\n' "$design_out"
    echo "This edit violates a CI-enforced check — fix it before moving on (AGENTS.md / DESIGN.md)."
  } >&2
  exit 2
fi
exit 0
