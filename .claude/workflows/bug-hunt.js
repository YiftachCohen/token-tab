export const meta = {
  name: 'bug-hunt',
  description: 'Hunt for real bugs across Token Tab: dimension finders, adversarial verification, ranked report',
  whenToUse: 'Run before a release, after a large refactor, or whenever you want a correctness sweep of the two engines. Workflow({name:"bug-hunt"}) sweeps the whole repo at standard depth (~34 agents); args:{depth:"quick"} (~15) or {depth:"deep"} (~68) sets how hard it looks; args:{scope:"diff"} narrows it to what this branch changed vs main.',
  phases: [
    { title: 'Recon', detail: 'map the parity pairs, the fixtures, and what CI already enforces' },
    { title: 'Hunt', detail: 'one finder per bug dimension, each blind to the others' },
    { title: 'Verify', detail: 'independent lenses try to reproduce and to refute every finding' },
    { title: 'Triage', detail: 'dedup, rank, and report — plus a critic on what went unlooked-at' },
  ],
}

// ---------------------------------------------------------------------------
// Depth presets. `standard` is the default; `deep` adds a second hunting round
// seeded with what round 1 already found, so round 2 is pushed into new ground.
// ---------------------------------------------------------------------------
// maxVerify is a HARD ceiling on findings verified per round, not a per-dimension
// quota — verification is where the agents actually go, so it is what bounds cost.
const DEPTHS = {
  quick: { finders: 4, lenses: ['reproduce'], maxVerify: 8, rounds: 1 },
  standard: { finders: 7, lenses: ['reproduce', 'refute'], maxVerify: 12, rounds: 1 },
  deep: { finders: 7, lenses: ['reproduce', 'refute', 'impact'], maxVerify: 10, rounds: 2 },
}

const opt = typeof args === 'string' ? { depth: args } : args || {}
const depth = DEPTHS[opt.depth] ? opt.depth : 'standard'
const cfg = DEPTHS[depth]
const scope = opt.scope === 'diff' ? 'diff' : 'repo'

// A generous budget is a mandate to look harder, not to look wider: it buys more
// verification lenses, which is where false findings actually die.
const lenses = budget.total && budget.total > 400_000 && depth !== 'quick'
  ? ['reproduce', 'refute', 'impact']
  : cfg.lenses

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------
const SEVERITY = ['critical', 'high', 'medium', 'low']

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'file', 'line', 'severity', 'trigger', 'wrong', 'expected', 'confidence'],
        properties: {
          title: { type: 'string', description: 'One line, the defect itself — not the area it lives in' },
          file: { type: 'string', description: 'Repo-relative path' },
          line: { type: 'integer', description: '1-indexed line the bug anchors to' },
          alsoAt: { type: 'array', items: { type: 'string' }, description: 'Other file:line the same bug touches' },
          severity: { type: 'string', enum: SEVERITY },
          trigger: { type: 'string', description: 'Concrete input or state that reaches the bug' },
          wrong: { type: 'string', description: 'What the code actually produces for that input' },
          expected: { type: 'string', description: 'What it should produce, and why that is the right answer' },
          confidence: { type: 'number', description: '0..1 — your own honest read before verification' },
          suggestedFix: { type: 'string' },
        },
      },
    },
    coverageNotes: { type: 'string', description: 'What you read, and anything you could not reach' },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['holds', 'confidence', 'evidence'],
  properties: {
    holds: { type: 'boolean', description: 'true = the finding survives this lens' },
    confidence: { type: 'number' },
    evidence: { type: 'string', description: 'Cited lines, or the command you ran and its output' },
    correctedSeverity: { type: 'string', enum: SEVERITY },
    notes: { type: 'string' },
  },
}

const REPORT_SCHEMA = {
  type: 'object',
  required: ['bugs', 'summary'],
  properties: {
    summary: { type: 'string', description: '2-4 sentences: what is actually broken and what to fix first' },
    bugs: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'file', 'line', 'severity', 'why', 'repro', 'fix'],
        properties: {
          title: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: SEVERITY },
          dimensions: { type: 'array', items: { type: 'string' } },
          why: { type: 'string', description: 'The defect and its user-visible consequence' },
          repro: { type: 'string', description: 'Input → wrong output, concrete enough to paste into a test' },
          fix: { type: 'string' },
          breaksParity: { type: 'boolean', description: 'true if fixing it requires mirroring into the other engine' },
          breaksInvariant: { type: 'string', description: 'Which AGENTS.md trust invariant, if any' },
        },
      },
    },
  },
}

// ---------------------------------------------------------------------------
// House rules every agent gets. Most bug-hunt noise comes from an agent that does
// not know what this repo has *decided*; this is the decision list.
// ---------------------------------------------------------------------------
const GROUND_RULES = `
## The repo

Token Tab reads local Claude Code / Codex JSONL logs and shows token usage in the macOS menu
bar. Read CLAUDE.md and AGENTS.md first — they are short and they are binding.

Two parsing engines are kept in deliberate parity and MUST agree:
  JS    src/core.mjs, src/pricing.mjs, src/codex.mjs, src/live-parse.mjs
  Swift app/Sources/TokenTabCore/Core.swift, Pricing.swift, LiveParse.swift, Format.swift
Shared proof fixtures: test/fixtures/parity/*.json, loaded by BOTH test/parity.test.mjs and
app/Tests/TokenTabCoreTests/ParityTests.swift.

## Read-only

Do NOT edit, create, or delete any file inside the repo — not source, not tests, not fixtures.
This is a hunt, not a fix. If you want to run a repro, write the scratch file OUTSIDE the repo
(under $TMPDIR, e.g. $TMPDIR/token-tab-bug-hunt-<something-unique>) and run it from there.
\`node --test\` and \`node -e '...'\` against the repo are fine and encouraged — proving a bug by
running it beats arguing for it. \`swift test --package-path app\` only works on macOS with a
Swift toolchain; if it is unavailable, say so and reason from the source instead of guessing.

## What counts as a bug

A defect where some reachable input produces a wrong answer, a crash, a hang, or a broken trust
claim. You must be able to name the input. "This looks fragile" is not a finding.

Rank by what it does to the number on the user's menu bar: a silently wrong token/dollar total
is the worst thing this product can do, and a trust-invariant break is worse still.

## What is NOT a bug (do not report these)

- Documented tolerances, all stated in the source headers: dollars are an estimate not an
  invoice; Bedrock region surcharges and >272K long-context surcharges are not modeled; cache
  TTL is assumed 5m; the rate table is not date-aware, so list price is used over promo price.
- Missing features, missing models with no published rate (unpriced is the deliberate,
  documented behavior — "tracked tokens, untracked price"), or absent test coverage on its own.
- Anything the CI audit already fails on. \`.github/scripts/trust-audit.sh\`,
  \`.github/scripts/rates-parity.mjs\` and \`.github/scripts/design-lint.sh\` run on every PR.
  A violation that those scripts CATCH is not a finding — the interesting bug is the one that
  passes all three and is still wrong (e.g. content read through a field the grep does not
  name, or a rate that matches JS↔Swift but is the wrong number in both).
- Style, naming, formatting, comment wording, or "I would have structured this differently".
- Design-system deviations — DESIGN.md compliance is a separate lint, not this hunt.

## Output

Every finding needs file, 1-indexed line, the triggering input, the wrong output, and the right
answer. No line number you have not actually read. Report at most 5 findings; if you have more,
send the 5 that are most likely to be real. Zero findings is a completely acceptable answer and
is much better than a padded list.
`

// ---------------------------------------------------------------------------
// Dimensions. Order matters: the first four are the `quick` set, chosen because
// they cover where this codebase's numbers actually go wrong.
// ---------------------------------------------------------------------------
const DIMENSIONS = [
  {
    key: 'parity',
    title: 'JS ↔ Swift engine divergence',
    prompt: `Find places where the JS engine and the Swift port DISAGREE on behavior for some input.

Diff them function by function, not file by file. High-yield pairs:
- dedup and keep-last resolution: the \`\${messageId}:\${requestId}\` key, the no-key path that must
  never collapse two records, duplicatesDropped / collisionsDifferingTotals accounting.
- classifySurface / normalizeModel / canonicalModelId: region prefixes (us|eu|apac|us-gov),
  the \`anthropic.\` vendor prefix, \`-vN:M\`, the trailing \`-YYYYMMDD\`, the \`[1m]\` suffix, case
  sensitivity, and the bare sonnet/opus/haiku aliases. Feed each engine the same weird id and
  check they land on the same key. An id shape one canonicalizer strips and the other does not
  routes to a different rate — silently wrong dollars.
- the 5h window blocks: block start anchoring, the gap rule, the block-end crossing rule, which
  block counts as active, calibratedCap over COMPLETED blocks only, resetAt, pct rounding.
- window/today/week boundary comparisons: strict vs non-strict (\`>\` vs \`>=\`) on the rolling
  cutoff, the week start, and the future-dated clamp. One engine using the other's comparison
  is a real off-by-one at the boundary.
- per-provider buckets: provider defaulting to "claude", which records feed Claude's window
  stamps, whether cost blocks appear only when pricing is injected.
- the Codex official-window classifier: window_minutes 300 / 10080, the declared-wins-collision
  rule, dropping a window with no used_percent, and epoch normalization (seconds vs ms).
- integer vs floating point: JS numbers are all doubles; Swift has Int/Double. Look for a place
  where Swift overflows, truncates, or rounds where JS does not.

For each finding, give the exact input record(s) and both engines' outputs.`,
  },
  {
    key: 'aggregation',
    title: 'Aggregation, dedup and window math',
    prompt: `Hunt correctness bugs in the aggregation itself — in BOTH engines, but judged on the math
rather than on whether they agree (two engines can be identically wrong).

Attack, in \`aggregate()\` (src/core.mjs) and its Swift twin:
- Dedup: streaming emits several usage lines per message and output_tokens GROWS, so last wins.
  Is last-write-wins actually guaranteed by the iteration order the callers supply? What if the
  final line has a SMALLER total? What if messageId exists but requestId does not, or either is
  an empty string, 0, or null — does the truthiness check do what the comment claims?
- The future-dated clamp (\`tms <= now\`): total includes it, the windows exclude it. Check every
  window uses the clamp, including the cost mirrors and the provider buckets.
- rolling5h is documented half-open \`(now-5h, now]\`. Verify the code implements exactly that,
  and that the block-building pass and the rolling pass do not disagree about the boundary.
- Block building: \`s.t - last.lastT <= blockMs && s.t < last.start + blockMs\`. Construct
  timestamp sequences that split a block where it should not, or merge two blocks that should
  be separate. Consider identical timestamps, out-of-order arrival (stamps are sorted — are
  they sorted everywhere they need to be?), and a single record.
- calibratedCap when there are no completed blocks, when the only block is active, and when a
  completed block is larger than the cap.
- Records with malformed or absent usage, absent timestamp, an unparseable timestamp, a
  negative or non-integer token count, and a numeric field that arrives as a string.
- Whether any counter (counted, untracked, unpriced) can double-count or miss a record.

Prove each one by running it: \`node -e\` importing src/core.mjs is the fastest evidence.`,
  },
  {
    key: 'pricing',
    title: 'Pricing, rate tables and cost math',
    prompt: `Hunt bugs in the dollars layer: src/pricing.mjs, app/Sources/TokenTabCore/Pricing.swift,
and the coverage fixtures in test/fixtures/parity/.

Attack:
- Cache multipliers per provider (claude write 1.25× / read 0.10×; codex write 0 / read 0.10×).
  Verify the multiplier actually applied matches the record's provider, not the default, on
  every path — including a record whose provider is absent, unknown, or misspelled.
- Alias resolution: \`rates[id] || rates[aliases[id]]\`. What happens when an alias points at a
  model id that is not in the table, or when a rate entry is legitimately falsy? Does the bare
  alias resolve to the family's CURRENT model in both engines and in both directions?
- Rate VALUES, against the published list prices: a number that is wrong identically in JS and
  Swift passes rates-parity.mjs and every parity fixture, and still bills wrong. Check the
  Claude table and the OpenAI/Codex table entry by entry, including the note about Terra/Luna
  being repriced down on 2026-07-30. Flag only rates you can actually source — never guess a
  number, and per the rules do not report a model's absence as a bug.
- The \`[1m]\` tier: stripped before lookup and priced at the base rate. Is it stripped
  consistently everywhere a model id is used as a key (cost, byModel, bySurface)?
- costOfUsage precision: order of accumulation, dividing by 1e6 once vs per class, and whether
  an enormous cache_read count can lose precision or overflow in Swift.
- unpriced accounting: tokens still counted, dollars not; unpricedModels deduped and sorted;
  per-provider cost buckets not inflated by another provider's priced records.
- The three-way contract in AGENTS.md (JS table, Swift table, rates-all-models fixture): find a
  way for all three to be mutually consistent and still produce a wrong total.`,
  },
  {
    key: 'invariants',
    title: 'Trust invariants — the ones the greps cannot see',
    prompt: `The product's whole claim is four invariants (AGENTS.md): zero runtime deps; no network and
no subprocess in src/ or app/Sources; never read message content; the app cannot phone home
(sandbox entitlements). CI greps for them. Your job is the violations a REGEX CANNOT SEE.

Hunt for:
- Content leakage by another name. The grep bans \`.content\` in src/ and \`message.content\` /
  \`"content"\` in app/Sources. Is any message text nonetheless read, retained, logged, or
  written to disk under a different field name, via a whole-object copy, a JSON re-serialize,
  a dictionary passthrough, an error message that embeds the offending line, or a debug/print
  path? Check what the Swift Codable structs actually decode and what the cache files, the
  live-output parser and any logging write out. A crash report or a thrown error carrying a raw
  log line is a content leak.
- Project names, file paths and other PII in anything persisted or rendered — the screenshot
  note in AGENTS.md exists because a real snapshot leaks project names.
- Subprocess or network reachable from an audited tree by indirection: a helper in
  adapters/ or app/Helper/ invoked from src/ or app/Sources, a dynamic import, a shell out
  through an env var, a file written into a path something else executes.
- The two fenced live paths (adapters/claude-live.mjs, app/Helper/main.swift): do they do
  ONLY \`claude -p "/usage"\` → parse → write the cache? Check argument construction and any
  path interpolation for injection, and check the cache file write for a symlink/TOCTOU or
  permissions problem.
- app/Bundle/TokenTab.entitlements: still exactly app-sandbox + files.user-selected.read-only,
  with nothing in Info.plist or Package.swift re-granting what the entitlements withhold.
- package.json dependencies stays {} — including a dep smuggled in via optionalDependencies,
  peerDependencies, or a bundled file under files[].

Report a finding only if the CI audit would PASS and the invariant is still broken. Say which
invariant, and what an auditor reading the README's trust claim would conclude.`,
  },
  {
    key: 'timezone',
    title: 'Time, timezone and clock correctness',
    prompt: `CI runs the suite under UTC, Pacific/Auckland and America/Los_Angeles because this codebase
has a local-calendar problem. Hunt what those three still miss.

Attack:
- localDayKey / startOfLocalWeek and their Swift twins: DST spring-forward (a day with no 02:00)
  and fall-back (a repeated hour), a week that starts on the DST boundary, and half-hour /
  45-minute offsets (Asia/Kolkata, Australia/Eucla, Pacific/Chatham) — Auckland and LA are both
  whole-hour zones, so a 30-minute offset bug survives CI.
- \`new Date(y, m, d)\` local-midnight construction where local midnight does not exist.
- weekStartsOn: 0 vs 1, and any value outside 0..6.
- Timestamp parsing: what src/ accepts vs what Swift's date parsing accepts. Fractional seconds,
  no fractional seconds, \`Z\` vs \`+00:00\`, a missing timezone entirely (does one engine read it
  as local and the other as UTC?), and epoch numbers.
- toEpochMs's seconds-vs-milliseconds heuristic (\`v >= 1e12\`): find real values where it picks
  wrong, and check the Swift reader uses the same threshold.
- \`resetAt\` / \`msToReset\` when the window straddles a DST change, and the rendered countdown
  when msToReset is negative or enormous.
- Any place a UTC log timestamp is compared against a local-calendar boundary without
  conversion, or a Date is formatted with a locale-dependent formatter.

Where you can, prove it: \`TZ=Pacific/Chatham node -e '...'\` and \`TZ=... node --test\`.`,
  },
  {
    key: 'io',
    title: 'File IO, CLI and app runtime',
    prompt: `Hunt bugs in everything around the pure core: src/token-tab.mjs, src/codex.mjs,
adapters/*.mjs, swiftbar/, and app/Sources/TokenTab/Model/ (LogReader, CodexLogReader,
UsageStore, FolderWatcher, LiveReader, LiveHelperManager, Config, Access, Probe).

Attack:
- JSONL reading: a truncated final line (the file is being appended to RIGHT NOW), a line
  exceeding the buffer, invalid UTF-8, a BOM, CRLF, an empty file, a file that is a directory
  or a broken symlink, and a line that is valid JSON but not an object.
- Ordering: the core's keep-last dedup depends on deterministic file-mtime + line order. Verify
  the readers actually deliver that, including two files with identical mtimes and a file
  rewritten during the read.
- Watching and refresh: FolderWatcher missing events, coalescing them wrongly, or looping; a
  read that races a concurrent write; the cache file read while the helper writes it (partial
  JSON); unbounded growth or a retain cycle in UsageStore.
- Concurrency in the app: work off the main actor mutating view state, an await that lets two
  refreshes interleave, or a Task that outlives its view.
- CLI: argument parsing (unknown flags, \`--\` handling, a flag given twice, a numeric flag given
  a non-number), exit codes, output when ~/.claude does not exist or is unreadable, --swiftbar
  output escaping (a project name containing \`|\` or a newline breaks SwiftBar's format), and
  JSON output that is not valid JSON for some input.
- Missing/denied paths: sandbox denial, a home directory without ~/.claude, permissions errors
  surfaced as a crash rather than a clean message.
- adapters/install-live.sh and app/Scripts: quoting of paths containing spaces.`,
  },
  {
    key: 'fixtures',
    title: 'Tests and fixtures that prove less than they claim',
    prompt: `The parity fixtures ARE the proof of two-engine parity, and the test suite is the only thing
standing between a refactor and a silently wrong menu bar. Hunt for tests that pass without
proving what they claim.

Attack:
- test/fixtures/parity/*.json: each fixture asserts only the fields it pins. Find a fixture
  whose expectations are so thin that a real behavior change would keep it green — especially
  around dedup, surface routing, the window, and per-provider isolation.
- Verify the fixture EXPECTATIONS are arithmetically right. Recompute a couple by hand: a
  fixture that pins a wrong number teaches both engines the same wrong behavior, forever.
  rates-all-models.json is worth recomputing (total, bySurface, cost.total, each cost.byModel).
- Find behavior asserted in the JS suite that has NO Swift twin, and vice versa — AGENTS.md
  requires twins. Name the specific JS test and the missing Swift counterpart (or the reverse).
- Assertions that cannot fail: comparing a value to itself, asserting a truthy object, a
  try/catch that swallows, an async assertion never awaited, a subtest never run, a test whose
  name says one thing and whose body checks another.
- Fixtures pinning \`today\` / \`cost.today\` that are NOT timezone-independent — AGENTS.md warns
  these are local-calendar values. A fixture that only passes in some zones is a latent CI break.
- rates-coverage: it asserts set equality of KEYS. Confirm nothing about the VALUES is
  assumed to be covered by it that only rates-parity.mjs actually checks.

Run \`node --test\` and read what it actually asserts. A test you can delete without turning the
suite red is a finding — name it and say what it was supposed to catch.`,
  },
]

// ---------------------------------------------------------------------------
// Phase 1 — Recon. One shared, accurate map beats seven agents each guessing at
// the layout, and it is what keeps findings anchored to real line numbers.
// ---------------------------------------------------------------------------
phase('Recon')

const recon = await agent(
  `You are the scout for a bug hunt on the Token Tab repo. Produce a compact factual BRIEF that
seven hunters will each be given as context. You are not looking for bugs — you are drawing the map.

${GROUND_RULES}

Scope for this hunt: ${scope === 'diff' ? 'ONLY what this branch changed vs main (run `git diff --stat main...HEAD` and `git diff main...HEAD --name-only`; list the changed files and the functions they touch)' : 'the whole repo'}.

Do this:
1. Read CLAUDE.md, AGENTS.md, and the file headers of src/core.mjs, src/pricing.mjs, src/codex.mjs
   and app/Sources/TokenTabCore/Core.swift, Pricing.swift.
2. List the JS↔Swift function pairs that are supposed to be in parity: exported name, JS
   file:line, Swift file:line. This is the single most useful thing in the brief — be exhaustive
   and be exact about line numbers.
3. List test/fixtures/parity/*.json with one line each on what behavior it pins.
4. Run \`node --test\` and report the actual pass/fail counts. Check whether \`swift\` exists
   (\`which swift\`); if not, say so plainly — hunters must not claim they ran Swift tests.
5. Note the last few commits (\`git log --oneline -15\`) and anything recently churned, since
   fresh code is where bugs are.
6. Note anything structurally surprising you noticed — a function with no twin, a fixture with
   no counterpart, a TODO, a comment admitting a known gap.

Return the brief as compact markdown under 700 words. Facts and file:line references only, no
speculation and no bug claims.`,
  { label: 'recon', phase: 'Recon' },
)

const BRIEF = recon
  ? `\n## Recon brief (from the scout — verify anything you rely on)\n\n${recon}\n`
  : '\n(No recon brief available — map the code yourself before hunting.)\n'

// ---------------------------------------------------------------------------
// Phases 2+3 — Hunt → Verify, as a pipeline. A dimension's findings go into
// verification the moment that dimension finishes; nothing waits on the slowest
// finder. Dedup happens after, in triage, where it is cheap plain code.
// ---------------------------------------------------------------------------
const LENS_PROMPTS = {
  reproduce: (f) => `Your lens is REPRODUCE. Ignore the reporter's confidence entirely.

Construct the concrete input that triggers this and trace the actual code, line by line, to the
wrong output. Where the code is reachable from Node, RUN IT — write a scratch script OUTSIDE the
repo (under $TMPDIR) that imports the real module and prints the actual result, or use
\`node -e\`. Quote the command and its real output as evidence. Never edit repo files.

Set holds=true ONLY if you produced the wrong behavior, or traced an unbroken path to it with
cited line numbers. If the trigger cannot actually occur — the caller never passes that shape,
a guard upstream rejects it, the branch is dead — set holds=false and say where it dies.

Claimed bug: ${f.title}
  ${f.file}:${f.line}${f.alsoAt && f.alsoAt.length ? ` (also ${f.alsoAt.join(', ')})` : ''}
  trigger:  ${f.trigger}
  wrong:    ${f.wrong}
  expected: ${f.expected}`,

  refute: (f) => `Your lens is REFUTE. Your job is to KILL this finding, and you should expect to
succeed — most bug reports from a code sweep are wrong. Default to holds=false when uncertain.

Look for: a guard the reporter missed; a caller that makes the input unreachable; a documented,
deliberate behavior in AGENTS.md, CLAUDE.md, a source comment, or a test that pins exactly this
behavior on purpose; a misread of the code; a line number that does not say what they claim it
says (go read it); the CI audit already catching it; or the "not a bug" list in the rules above.

Set holds=true only if you tried hard and could not kill it. Cite the specific lines either way.

Claimed bug: ${f.title}
  ${f.file}:${f.line}
  trigger:  ${f.trigger}
  wrong:    ${f.wrong}
  expected: ${f.expected}`,

  impact: (f) => `Your lens is IMPACT. Assume the mechanism is real; judge whether it MATTERS.

Does a real user hit this with a real ~/.claude log, and what do they see — a wrong number on
the menu bar, a wrong dollar figure, a crash, a broken trust claim, or nothing observable?
Follow the value from this line to what is actually rendered or written. If it is masked
downstream (clamped, overwritten, rounded away, never displayed), say so and set holds=false.

Then set correctedSeverity honestly: critical = wrong totals or a broken trust invariant that a
normal user hits; high = wrong numbers on a plausible input; medium = a real but narrow edge
case; low = cosmetic or unreachable in practice.

Claimed bug: ${f.title}
  ${f.file}:${f.line}
  trigger:  ${f.trigger}
  wrong:    ${f.wrong}
  expected: ${f.expected}`,
}

function verifyFinding(f, dim) {
  return parallel(
    lenses.map((lens) => () =>
      agent(`${LENS_PROMPTS[lens](f)}\n\n${GROUND_RULES}`, {
        label: `${lens}:${f.file.split('/').pop()}:${f.line}`,
        phase: 'Verify',
        schema: VERDICT_SCHEMA,
      }),
    ),
  ).then((verdicts) => {
    const got = verdicts.filter(Boolean)
    // Every lens is a veto in a different direction, so require a real majority and
    // treat a dead lens as a non-vote rather than as assent.
    const held = got.filter((v) => v.holds).length
    const corrected = got.map((v) => v.correctedSeverity).filter(Boolean)
    return {
      ...f,
      dimension: dim,
      verdicts: got,
      confirmed: got.length > 0 && held * 2 > got.length,
      severity: corrected.length ? corrected.sort((a, b) => SEVERITY.indexOf(a) - SEVERITY.indexOf(b))[0] : f.severity,
    }
  })
}

async function huntRound(round, alreadyFound) {
  const dims = DIMENSIONS.slice(0, cfg.finders)
  // Round 1 does the broad sweep; a later round is a top-up over ground round 1
  // missed, so it gets half the verification budget.
  const roundCap = round === 1 ? cfg.maxVerify : Math.ceil(cfg.maxVerify / 2)
  // Every dimension is guaranteed one verification slot — the quietest finder is
  // often the one holding the real bug — and the surplus is first-come.
  let surplus = Math.max(0, roundCap - dims.length)
  let dropped = 0
  const claim = (want) => {
    const guaranteed = Math.min(want, 1)
    const extra = Math.min(want - guaranteed, surplus)
    surplus -= extra
    dropped += want - guaranteed - extra
    return guaranteed + extra
  }

  const seen = alreadyFound.length
    ? `\n## Already found in an earlier round — do NOT report these again\n\n${alreadyFound
        .map((f) => `- ${f.file}:${f.line} — ${f.title}`)
        .join('\n')}\n\nThose areas have been picked over. Go where round 1 did not look: the paths it
skipped, the inputs it did not think of, the file in your dimension it never opened.\n`
    : ''

  return pipeline(
    dims,
    (d) =>
      agent(
        `You are hunting for bugs in the Token Tab repo. Your dimension is: ${d.title}.
${round > 1 ? `This is hunting round ${round}.` : ''}

${d.prompt}
${BRIEF}${seen}
${GROUND_RULES}`,
        { label: `hunt:${d.key}${round > 1 ? `:r${round}` : ''}`, phase: 'Hunt', schema: FINDINGS_SCHEMA },
      ),
    (res, d) => {
      if (!res || !res.findings || !res.findings.length) return []
      // Verify the most-promising first, so if the cap bites it drops the weakest.
      const ranked = [...res.findings].sort(
        (a, b) => SEVERITY.indexOf(a.severity) - SEVERITY.indexOf(b.severity) || b.confidence - a.confidence,
      )
      const take = ranked.slice(0, claim(ranked.length))
      if (ranked.length > take.length) {
        log(`${d.key}: verifying ${take.length} of ${ranked.length} findings — ${ranked.length - take.length} dropped, round cap ${roundCap}`)
      }
      return parallel(take.map((f) => () => verifyFinding(f, d.key)))
    },
  ).then((out) => {
    if (dropped) log(`round ${round}: ${dropped} findings went unverified at the cap — re-run at greater depth to reach them`)
    return out
  })
}

phase('Hunt')
// State the ceiling up front — a hunt that quietly costs 4x what you expected is
// a worse tool than one that tells you before it starts. Each round verifies at
// most its cap, but never fewer than one finding per dimension (the guaranteed
// slot in claim()), so a small round cap floors at the dimension count.
let verifyCeiling = 0
for (let r = 1; r <= cfg.rounds; r++) {
  verifyCeiling += Math.max(r === 1 ? cfg.maxVerify : Math.ceil(cfg.maxVerify / 2), cfg.finders)
}
log(
  `bug-hunt — depth=${depth}, scope=${scope}, ${cfg.finders} dimensions x ${cfg.rounds} round(s), ` +
    `lenses: ${lenses.join('+')}${lenses !== cfg.lenses ? ' (upgraded, large budget)' : ''}. ` +
    `At most ${1 + cfg.finders * cfg.rounds + verifyCeiling * lenses.length + 2} agents.`,
)

const all = []
for (let round = 1; round <= cfg.rounds; round++) {
  const res = await huntRound(round, all)
  const flat = res.flat().filter(Boolean)
  all.push(...flat)
  log(`round ${round}: ${flat.length} findings verified, ${flat.filter((f) => f.confirmed).length} survived`)
}

const confirmed = all.filter((f) => f.confirmed)
const rejected = all.filter((f) => !f.confirmed)

// ---------------------------------------------------------------------------
// Phase 4 — Triage. Dedup across dimensions happens here (post-verification, so a
// bug found by two dimensions gets two independent reads before they are merged),
// alongside a critic that says what the hunt did not look at.
// ---------------------------------------------------------------------------
phase('Triage')

if (!confirmed.length) {
  log(`no findings survived verification (${rejected.length} rejected)`)
  const critic = await agent(
    `A bug hunt over the Token Tab repo just finished and NOTHING survived verification.
${rejected.length} candidate findings were refuted. Dimensions hunted: ${DIMENSIONS.slice(0, cfg.finders)
      .map((d) => d.key)
      .join(', ')}.

Refuted candidates:
${rejected.map((f) => `- [${f.dimension}] ${f.file}:${f.line} — ${f.title}\n  killed by: ${f.verdicts.filter((v) => !v.holds).map((v) => v.evidence).join(' | ').slice(0, 400)}`).join('\n') || '(none)'}

Judge honestly, in under 300 words: was the code clean, or was the hunt shallow? Name the
specific paths, inputs, or files that went unexamined and would be worth a second pass, and any
refutation above that looks wrong to you. Read the code where you need to.

${GROUND_RULES}`,
    { label: 'critic', phase: 'Triage' },
  )
  return {
    depth,
    scope,
    lenses,
    hunted: DIMENSIONS.slice(0, cfg.finders).map((d) => d.key),
    verified: all.length,
    confirmedCount: 0,
    rejectedCount: rejected.length,
    report: { summary: 'No finding survived verification.', bugs: [] },
    rejected: rejected.map((f) => ({
      file: f.file,
      line: f.line,
      title: f.title,
      killedBy: f.verdicts.filter((v) => !v.holds).map((v) => v.evidence),
    })),
    critique: critic,
  }
}

const [report, critique] = await parallel([
  () =>
    agent(
      `You are triaging the surviving findings of a bug hunt on the Token Tab repo. Every finding
below already passed independent verification lenses (${lenses.join(', ')}).

${JSON.stringify(confirmed.map((f) => ({
  dimension: f.dimension,
  title: f.title,
  file: f.file,
  line: f.line,
  alsoAt: f.alsoAt,
  severity: f.severity,
  trigger: f.trigger,
  wrong: f.wrong,
  expected: f.expected,
  suggestedFix: f.suggestedFix,
  evidence: f.verdicts.map((v) => v.evidence),
})), null, 1)}

Do this:
1. MERGE duplicates — two dimensions often find the same defect from different sides. Same root
   cause = one bug, with both dimensions listed and the best evidence from each.
2. Open every cited file:line and CONFIRM it says what the finding claims. Drop anything that
   does not survive your own read, and say in the summary how many you dropped and why.
3. Rank by consequence to the number on the user's menu bar. A trust-invariant break outranks
   everything.
4. For each bug write: what breaks and what the user sees; a repro concrete enough to paste into
   test/core.test.mjs or a parity fixture; and the fix. Set breaksParity=true when the fix must
   be mirrored into the other engine — for anything in the two cores, it almost always must be,
   and per AGENTS.md a behavior change also needs a shared fixture in test/fixtures/parity/.

${GROUND_RULES}`,
      { label: 'triage', phase: 'Triage', schema: REPORT_SCHEMA },
    ),
  () =>
    agent(
      `A bug hunt over the Token Tab repo just finished. It ran these dimensions: ${DIMENSIONS.slice(
        0,
        cfg.finders,
      )
        .map((d) => d.key)
        .join(', ')} (depth=${depth}, scope=${scope}).

Confirmed: ${confirmed.map((f) => `${f.file}:${f.line} ${f.title}`).join('; ') || 'none'}
Refuted: ${rejected.map((f) => `${f.file}:${f.line} ${f.title}`).join('; ') || 'none'}

You are the completeness critic. In under 300 words, name what this hunt did NOT cover: a file
nobody opened, an input class nobody tried, a claim asserted but never actually executed, a
refutation that looks wrong. Be specific enough that each item is directly actionable as the
next round. Read the code where you need to. Do not restate the findings.

${GROUND_RULES}`,
      { label: 'critic', phase: 'Triage' },
    ),
])

return {
  depth,
  scope,
  lenses,
  hunted: DIMENSIONS.slice(0, cfg.finders).map((d) => d.key),
  verified: all.length,
  confirmedCount: confirmed.length,
  rejectedCount: rejected.length,
  report,
  rejected: rejected.map((f) => ({
    file: f.file,
    line: f.line,
    title: f.title,
    killedBy: f.verdicts.filter((v) => !v.holds).map((v) => v.evidence),
  })),
  critique,
}
