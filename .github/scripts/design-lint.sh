#!/usr/bin/env bash
# Token Tab — design-token lint.
#
# DESIGN.md's rule, as a check: colors and typefaces are design tokens, and tokens live in
# app/Sources/TokenTab/Views/Theme.swift ONLY. A raw hex color or Font.custom anywhere else
# in the app target is drift — it can't follow the light/dark pairs, and the next redesign
# won't find it. Run by ci.yml and by the .claude post-edit hook.
#
# Ratchet, not amnesty: design-lint-baseline.txt lists the literals that predate this lint
# (each is a migration TODO — move it into Theme and delete its line). Anything NEW fails.
# The baseline holds "file:matched-literal" pairs, so fixing a line without deleting its
# baseline entry just leaves a stale entry; adding a literal always trips the lint.
set -u
cd "$(dirname "$0")/../.." || exit 1

baseline=.github/scripts/design-lint-baseline.txt

# Raw color literals (hex ints, component initializers) and custom-font calls.
pattern='0x[0-9a-fA-F]{6}|Color\(red:|Color\(hue:|srgbRed|NSColor\(hex|Color\(hex|Font\.custom\('

current="$(LC_ALL=C grep -RHoE "$pattern" app/Sources/TokenTab --include='*.swift' \
  | grep -v 'Views/Theme\.swift' | LC_ALL=C sort -u || true)"

new="$(LC_ALL=C comm -23 <(printf '%s\n' "$current") <(LC_ALL=C sort -u "$baseline"))"

if [ -n "$new" ]; then
  echo "::error::raw color/font literal outside Theme.swift — add a token to Theme instead (see DESIGN.md)"
  echo "$new"
  echo
  echo "If this literal is truly a new design token, add it to Theme.swift. Do not extend"
  echo "the baseline — it only exists for literals that predate this lint."
  exit 1
fi

stale="$(LC_ALL=C comm -13 <(printf '%s\n' "$current") <(LC_ALL=C sort -u "$baseline"))"
if [ -n "$stale" ]; then
  echo "stale design-lint baseline entries (the literal is gone — delete these lines to lock it in):"
  echo "$stale"
fi
exit 0
