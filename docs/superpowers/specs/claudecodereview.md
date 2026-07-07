Independent review of your Claude Code usage

Scope: ~240MB of transcripts across 6 projects (salesbot, MongodbUnpacked, LocalFlow, mongo-memory, Desktop), your prompt history (1,152 prompts), settings, and permissions. Analyzed by a 6-agent workflow plus first-hand review.

What you're doing right

1. The superpowers pipeline for greenfield builds — LocalFlow went from a one-sentence prompt to a working macOS app (144 tests, ~29h, only 2 interruptions). Your best session ever; the pipeline supplies the rigor your prompts skip.
2. Screenshot bug reports — your single most effective correction channel. "[Image] why" routinely diagnoses what paragraphs wouldn't.
3. Crisp answers to option menus — you converge fast on AskUserQuestion choices where your open prose is vague.
4. "Give me your honest view" pre-mortems, commit-before-change, phased low-risk plans, Monitor for long jobs, subagent fan-outs — all genuinely good practice.
5. You rewarding candor — sessions where Claude owned a breakage went better; that's on you and worth knowing.

What's costing you (ranked)

1. "Tests green ≠ works" (Claude's fault): repeated shipping of user-facing breakage behind green suites — no-op buttons, fake demo behavior, unserved CSS. You caught every one manually.
2. Zero-evidence bug reports (your habit): "nothing loads" ×17, "fix it", "retry" — each triggers a guess loop across server/port/cache/nginx/code.
3. State desync (both): you merge/push/deploy outside the session; Claude asserts from stale state ("I pushed it - I am notsure why you keep saying push it").
4. Cache/stale-serve masking real fixes — hours lost to "still broken" when the fix was fine but not served.
5. Marathon sessions: ~44 compactions in one 111MB session; standing rules (like your no-em-dash rule) kept dying in chat memory because nothing persisted them.
6. 43 /model switches, mostly liveness pokes during silent long phases; once caused a 5× resubmit loop.
7. 99% of tokens on the top model — even for mechanical work Sonnet handles fine if the discipline lives in files.

What I built (all in place now)

1. Seven skills in ~/.claude/skills/ (work in every project, on any model):

┌────────────────────┬────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────┐
│       Skill        │                     Fires when                     │                                          Encodes                                          │
├────────────────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ prove-it-works     │ before saying "done/fixed"                         │ drive the real artifact, no fake behavior, verify it's served                             │
├────────────────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ bug-intake         │ "nothing loads / fix it / retry"                   │ evidence pass before any edit; kills guess loops                                          │
├────────────────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ resync-state       │ "merged / pushed / deployed"                       │ re-check reality, clean branches, never nag                                               │
├────────────────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ ship-safe          │ risky change / "push it" / "will this break prod?" │ commit-first, full gate, fallback anchor, blast-radius audit                              │
├────────────────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ scope-playback     │ vague/typo/redo prompts                            │ bind the referent, one question on redos, persist smuggled requirements                   │
├────────────────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ long-job           │ anything >10 min                                   │ checkpoint files, failure-covering Monitors, heartbeat                                    │
├────────────────────┼────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ real-demo-doctrine │ any demo/agent page                                │ your demo architecture rules (real end-to-end, MongoDB visible, TTL, reset, no em dashes) │
└────────────────────┴────────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────────┘

2. CLAUDE.md, finally — the biggest gap I found (you had none anywhere):
- ~/.claude/CLAUDE.md — global standing rules: no em dashes, secrets handling, you-merge-you-deploy, done-means-verified, your prompting style notes.
- pipelinebuilder/CLAUDE.md — ship ritual, cache-buster discipline, the full EC2/SSM runbook (instance ID, container, safe.directory trick), feature flags, code choke points. Untracked in the repo — commit it when you're happy with it so it survives clones.

3. Guidance — written to ~/.claude/claude-code-guidance.md. The 8 habit changes with the highest leverage, in one line each: attach one line of evidence to bug reports; say what failed before demanding a redo; announce external merges/deploys immediately; define "done" as a demo script; start fresh sessions per work stream; don't /model-poke for liveness; give exact resource names (secret+region) up front; prefix standing rules with "NEW REQUIREMENT:".

4. Other cleanups:
- Replaced your junk permissions allowlist (one-off strings like a specific sed -n '45,140p') with ~28 semantic rules — fewer prompts, same safety.
- One thing only you can do: run gh auth login once. CLI PR creation has been silently failing across sessions; you've been opening PRs by URL the whole time.

On dropping to Opus/Sonnet: the discipline that made your sessions work was living in the model's judgment. It now lives in files that load every session regardless of model — so Sonnet can safely run your rituals (gates, branch hygiene, cache busters, resync), and you keep the top model for architecture, gnarly debugging, and prod. On weaker models, invoke skills by name if they don't fire on their own.