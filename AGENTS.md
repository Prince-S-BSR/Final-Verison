# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database
> (`.beads/dolt/`); cross-machine sync uses `bd dolt push/pull` (a
> git-compatible protocol), stored under `refs/dolt/data` on your git
> remote — separate from `refs/heads/*` where your code lives.
> `.beads/issues.jsonl` is a passive export, not the wire protocol.
>
> See [SYNC_CONCEPTS.md](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)
> for the one-screen overview and anti-patterns (don't treat JSONL as the
> source of truth; don't `bd import` during normal operation; don't
> reach for third-party Dolt hosting before trying the default).

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

## Git Policy Override

The Beads managed block above defaults to "do not commit/push without being asked." **This project overrides that**: a `Stop` hook in `.claude/settings.json` automatically runs `git add -A && git commit && git push origin HEAD` after every Claude turn that changes files. This was an explicit user request — no confirmation needed before committing/pushing in this project.

## Subagent Model Routing

`.claude/agents/` defines role-scoped subagents so routine work runs on Sonnet and only genuinely hard decisions escalate to Opus:

- `implementer`, `test-writer`, `ui-builder` — **Sonnet**. Default for CRUD, forms, tests, UI, bug fixes, refactors.
- `architect` — **Opus**. Reserved for schema/data-model design, multi-tenant access control, matching/scoring/ranking algorithms, migration strategy. Use sparingly.

Prefer the Sonnet-tier agents for implementation tasks; escalate to `architect` only for decisions that are expensive to reverse.

**Two independent layers govern agent behavior in this repo, and they answer different questions.** Layer 1 is this section — it determines WHICH model/agent performs work once that work is authorized. Layer 2 is `docs/BMEXA_MASTER_SPEC.md` §88 (the "Claude Autonomy Matrix") — it determines WHAT decisions may be made autonomously at all versus requiring the project owner's explicit approval first: canonical entities, relationships, booking lifecycle, financial rules, CP commission logic, tenant architecture, RLS, authorization, authentication, offline business behavior, source-of-truth rules, and audit requirements. Assigning work to `architect` (or to any subagent) does **not** itself satisfy Layer 2 — delegation is not authorization. No subagent may treat "I was asked to do this" as permission to decide one of the Layer-2 items on its own; those still require the project owner's explicit sign-off regardless of which model executes the eventual implementation.

## Skill Routing Protocol (Mandatory)

**Before executing any feature work, the active subagent MUST evaluate the workspace skills below and invoke the best-fit skill first.** Do not write code or perform task execution without first consulting the relevant skill(s) for the category the task falls into. This is a hard gate, not a suggestion — skipping it is a process error even if the resulting code would have been correct.

| Task category | Route to |
|---|---|
| Memory / persistent context | `claude-mem`, MemPalace |
| Task tracking / issue management | `bd` (beads), `task-observer` |
| UI styling / visual design judgment | Taste Skills (`.taste-skills/`), `web-design-guidelines` |
| Motion / animation | `animate`, `design-motion-principles` |
| Creative layouts / full page or design-system builds | `auteur`, `genjutsu` |
| Testing / QA | `playwright-cli`, `impeccable` |

Notes:
- `impeccable` is a design-anti-pattern/QA audit skill, not a test runner — pair it with `playwright-cli` for actual browser test execution; together they cover functional and visual/quality regression.
- Consulting a skill means invoking it (via the `Skill` tool or its slash command) or explicitly reading its guidance before acting — not just recalling that it exists.
- If no listed skill fits the task category, say so explicitly and proceed without one rather than silently skipping the check.
- This protocol governs the four role subagents (`architect`, `implementer`, `test-writer`, `ui-builder`) equally — model tier does not exempt a subagent from routing.
