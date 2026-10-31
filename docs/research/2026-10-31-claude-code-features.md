# Claude Code briefing as of 2026-10-31

Verified against code.claude.com docs: agent teams, cross-session messaging, hooks, skills, memory, effort, plugin evals, scheduled tasks, and plugins. The Workflow tool, Monitor, ultracode internals, Claude Dashboards, and Claude Design rest on secondary sources only, and they are flagged below.

## 1. Multi-agent

- **Subagents** return a result to the caller and cost fewer tokens. They suit focused work where only the answer matters. Source: https://code.claude.com/docs/en/sub-agents.md
- **Agent teams are experimental.** A lead plus teammates share a task list and message each other directly. Teams fit work where teammates must challenge each other: competing hypotheses, multi-lens review, or cross-layer work with clear file ownership. Same-file edits and sequential work fit neither well. Source: https://code.claude.com/docs/en/agent-teams.md
- **Team limits:** in-process teammates do not survive `/resume`, there is one team per session, teammates cannot spawn teammates, and shutdown is slow.
- **Config trap:** with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, any subagent Claude names launches as a teammate. Setting it to `0` reverts that.
- **Cross-session messaging needs no flag.** From v2.1.224 it is on by default on macOS and Linux. Same-machine messages travel over a local socket, never through Anthropic servers. Cross-machine or cloud reach needs Remote Control and a claude.ai sign-in, so API-key sessions cannot see those sessions. Inbound messages default to prompting, and `crossSessionInbound` can be `accept`, `hold`, or `refuse`. This fits the five-Claudes setup better than teams do. Source: https://code.claude.com/docs/en/cross-session-messaging.md
- **Scheduled tasks** (formerly routines) run in the cloud on a schedule, an API call, or a GitHub event. They are a research preview on paid plans. Cloud sessions do not load your local plugins. Sources: https://code.claude.com/docs/en/routines.md and https://code.claude.com/docs/en/plugins.md
- **Workflow tool and ultracode:** secondary sources describe scripts that orchestrate subagents deterministically, with resume only inside the same session. The effort docs confirm `ultracode` is a setting that starts at `xhigh` with workflows on. I could not confirm the Workflow script mechanics officially. Source: https://code.claude.com/docs/en/model-config.md

## 2. Memory, context, configuration

- **CLAUDE.md and auto memory.** Auto memory is per repository and shared across worktrees. The first 200 lines or 25KB load each session. Source: https://code.claude.com/docs/en/memory.md
- **Rules.** `.claude/rules/*.md` loads recursively. A `paths:` frontmatter key scopes a rule to matching files. `~/.claude/rules/` applies to every project.
- **Skills replace commands.** `.claude/commands/` still works, but the docs recommend skills for new work. A skill wins a name clash. Your existing `SKILL.md` directories are the current format. Source: https://code.claude.com/docs/en/skills.md
- **Hooks.** The hooks page lists 33 lifecycle events. Relevant to you: `SessionStart`, `PreToolUse`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`, `Stop`, `Notification`, `UserPromptSubmit`, `SessionEnd`, `InstructionsLoaded`, `FileChanged`, and the team hooks `TeammateIdle`, `TaskCreated`, `TaskCompleted`. I read only the first 100k characters of that page and saw no deprecation markers there. Source: https://code.claude.com/docs/en/hooks.md
- **Agent memory directories:** I could not confirm these in the docs. Do not rely on them.
- **Effort and context.** Levels are `low`, `medium`, `high`, `xhigh`, `max`. Opus 5.5, Sonnet 5.5, and Haiku 5.5 default to `medium`. The 1M window is the default for Sonnet 5 and later, Haiku 5.5, and Opus 4.7 and later. `/autocompact` sets the compaction threshold. Source: https://code.claude.com/docs/en/model-config.md

## 3. Plugins and quality tools

- **Marketplace.** The official marketplace is added automatically on first interactive start. Browse it with `/plugin` and the Discover tab. Source: https://code.claude.com/docs/en/plugins.md
- **Not verified.** I did not enumerate the official marketplace, so I cannot confirm which plugins help with game dev, image generation, or autonomous runs. Your three installed plugins are figma, playwright, and frontend-design.
- **Review tools,** per the harness: `/code-review` (with `ultra` as a billed, user-triggered cloud review), `/simplify` (quality cleanups, no bug hunting), and `/security-review` (branch security audit). `/ultrareview` is a deprecated alias for `/code-review ultra`.
- **`claude plugin eval`** is confirmed. It runs eval suites of prompts and graders for plugin authors, and `claude plugin eval init` scaffolds one. It is for plugin authors, not personal skills. Source: https://code.claude.com/docs/en/plugin-evals.md
- **`/skill-doctor`:** the harness mentions it, but I could not confirm its behavior in the docs.

## 4. Artifacts, Docs, Design, Dashboards

- **For a design bible,** keep the canonical spec in the repo as markdown. Claude Docs can hold editable sections that others comment on. A dashboard artifact can publish read-only progress. `ArtifactData` can hold tracker rows.
- **Unverified dates.** One secondary source says Docs, Slides, Design, and Dashboards left beta on 2026-10-08, and that the standalone Claude Design site closes 2026-12-14. Confirm both before building on them.

## 5. Long-running sessions

- **Tools.** `/loop` with no interval self-paces. Background agents run in worktrees (`claude --worktree`). The Monitor tool streams background output into the session. I could confirm Monitor only through third-party sources.
- **Compaction hooks.** `PreCompact` and `PostCompact` let you save state around compaction.
- **Effort and window settings** are covered in section 2.
- **Best practices.** Anthropic's best-practices guide exists at https://code.claude.com/docs/en/best-practices.md. I did not read it in this pass.

## 6. Images

- **Reading images works.** Drag, paste, or give a path, and Claude Code analyzes PNG screenshots and turns mockups into CSS. Source: https://code.claude.com/docs/en/common-workflows.md
- **No first-party generation.** Every source I found agrees Claude Code has no built-in image generation. Community MCP servers fill the gap.
- **PixelLab is already connected.** This session exposes PixelLab tools (characters, tilesets, animations, and a pixel-art workbench), so the third-party server mentioned in the request is not needed.

## Worth configuring now

- Decide on the team flag. Leave it off if you want subagents, and use cross-session messaging for the five-session setup.
- Keep `bd prime` as a `SessionStart` hook. It fits the lifecycle.
