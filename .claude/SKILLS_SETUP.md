# Claude Code environment setup — installation record

This file documents what was installed into this project's Claude Code environment, when, how, and with what caveats. Keep it updated if the setup changes.

## Scope note

Two different persistence levels are in play:

- **User-level** (lives in `~/.claude`, `~/.local`, etc. on whatever machine runs Claude Code) — not tracked by this repo. A collaborator or a different machine must re-run these installs independently.
- **Project-level** (lives under this repo, e.g. `.claude/skills/`, `.agents/skills/`, `.taste-skills/`, `.beads/`) — committed to git, so anyone who checks out this branch gets it automatically.

| # | Item | Type | Scope | Install command | Status |
|---|------|------|-------|------------------|--------|
| 1 | FindSkills | Discovery CLI | Ad hoc (`npx findskills`) | `npx findskills "<query>"` | CLI runs; live search API (findskills.org) is unreachable from this sandbox's network policy — works from a normal machine |
| 2 | claude-mem | Memory system (plugin + hooks) | User-level | `npx claude-mem@latest install --provider claude` | Installed, plugin enabled, worker verified responding on `127.0.0.1:37700` |
| 3 | Impeccable | Design-audit skill/plugin | User-level | `claude plugin marketplace add pbakaus/impeccable` + `claude plugin install impeccable@impeccable` | Installed and enabled (CDN-based `npx impeccable install` is blocked by this sandbox's egress policy; the git-based plugin path was used instead — works identically) |
| 4 | Task Observer | Meta-skill bundle | Project-level (`.claude/skills/task-observer/`) | Full bundle (`SKILL.md`, `references/`, `scripts/`) copied from `rebelytics/one-skill-to-rule-them-all` | Installed, self-validation script passed |
| 5 | MemPalace | Memory system | Project-level init (`mempalace.yaml`, gitignored) + user-level CLI/MCP | `uv tool install mempalace` → `mempalace init --yes .` → `claude mcp add mempalace -- mempalace-mcp` | Installed, MCP connection verified (`√ Connected`). **Not yet mined** — no project data has been ingested into it. See credibility caveat below before doing so. |
| 6 | Beads | Task/issue graph CLI | Project-level (`.beads/`, `CLAUDE.md`, `.claude/settings.json` hook) | `npm install -g @beads/bd` → `bd init` → `bd setup claude` | Installed, verified (`bd ready`, `bd list` working) |
| 7 | Taste Skills | Design-judgment skills (39 skills) | Project-level (`.taste-skills/`) | `npx github:Dragoon0x/taste-skills add --all` (note: actual org is `Dragoon0x`, not `0xDragoon` as some docs say) | Installed |
| 8 | Web Design Guidelines (+ 8 other Vercel skills) | Skill bundle | Project-level (`.agents/skills/`, symlinked into Claude Code) | `npx skills add vercel-labs/agent-skills` | Installed. This pulled the whole 9-skill Vercel bundle (deploy-to-vercel, vercel-cli-with-tokens, vercel-composition-patterns, vercel-optimize, vercel-react-best-practices, vercel-react-native-skills, vercel-react-view-transitions, web-design-guidelines, writing-guidelines) — kept intentionally, per your decision, since this CRM may deploy on Vercel. |
| 9 | Playwright CLI | Official Microsoft CLI | User-level (global npm) + project-level skill copy | `npm install -g @playwright/cli@latest`; skill manually copied to `.claude/skills/playwright-cli/` | CLI installed and verified (`--version` works). `playwright-cli install --skills` normally also downloads a Chromium build from `cdn.playwright.dev`, which this sandbox's network policy blocks — untested end-to-end browser automation here; will work on an unrestricted machine. |
| 10 | Awesome Design (FuturizeRush) | Curated list | — | Not installed | Paused per your instruction — unverified curator, 0 independently-confirmed signals |
| 11 | Awesome Design (VoltAgent) | Curated list (Claude Design templates) | — | Not installed | Skipped — wrong product (targets claude.ai/design, not Claude Code) |
| 12 | Image to Code | Skill | — | Not installed | No canonical project found; candidates presented for you to pick |

## Known caveats to keep in mind

- **MemPalace**: its own issue tracker has a "POSSIBLE SCAM REPO" thread and a documented false-benchmark-claims issue (#875). The PyPI package author field is literally `milla-jovovich`, matching the name in a public "how X scammed the internet" video referenced in that thread. Installed at your explicit instruction despite this. No hidden telemetry/exfiltration found in a source-level scan, and it defaults to local-only MCP (stdio, not networked) — but treat any of its output/benchmarks skeptically, and avoid `mempalace serve` (explicit remote HTTP sharing mode) unless you specifically intend to expose it to a team.
- **claude-mem**: captures full session content (tool calls, code, prompts) which can include secrets. Its own security audit (issue #1251) flags that its local worker API is unauthenticated. It defaults to `127.0.0.1` only — never set `CLAUDE_MEM_WORKER_HOST=0.0.0.0`.
- **Beads**: shares anonymous command-name/version/OS usage metrics by default. Opt out with `bd metrics off`.

## Classification

- **Design / Frontend**: Impeccable, Taste Skills, Web Design Guidelines (+ Vercel bundle)
- **Memory / Knowledge**: claude-mem, MemPalace
- **Task / Workflow**: Beads, Task Observer
- **Discovery**: FindSkills
- **Browser / Testing**: Playwright CLI
- **Not installed**: Graphify (no canonical project exists), Image to Code (no verified canonical project), Awesome Design ×2 (wrong product / unverified curator)

## Architecture recommendation for this CRM

1. **Beads is the task backbone.** It's already wired into `CLAUDE.md`/`AGENTS.md` and the SessionStart hook — every future session should file and track work there, not in ad hoc TODOs.
2. **Task Observer runs quietly alongside it**, watching sessions and proposing new skills/improvements over time — not a competing task tracker.
3. **claude-mem is the default memory layer** (auto-injects context every session, zero extra commands). Treat **MemPalace as opt-in/experimental** given its credibility problems — mine specific things into it deliberately rather than leaving it running unattended, and don't run `mempalace serve`.
4. **Design skills stack, they don't compete**: Impeccable audits against anti-patterns, Taste Skills sharpen subjective judgment calls, Web Design Guidelines checks objective accessibility/UX rules, and the Vercel skills apply if/when this ships on Vercel. Run them at different points in a feature's lifecycle (taste during design, guidelines + impeccable at review time) rather than all at once.
5. **Playwright CLI** is your regression-testing/browser-automation layer once real CRM screens exist to test.
6. **FindSkills** is a lookup tool for later — reach for it when you need a skill for something not already covered here.
