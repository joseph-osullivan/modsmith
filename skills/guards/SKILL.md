---
name: guards
description: "Opt-in self-correction layer for a Minecraft mod repo: a Stop hook that refuses to end a turn while the project's fast gate is red, /goal guidance for unattended runs, and /verify in the Lane 1 step order. Installs nothing without the user picking each guard."
when_to_use: "The user asks to 'add the guards', 'make Claude check its work before stopping', 'set up for an overnight run', or a modsmith skill suggests it. Never auto-applied by /modsmith:develop."
user-invocable: true
disable-model-invocation: true
allowed-tools: Read, Glob, Grep, Bash, Write, Edit, AskUserQuestion
---

# /modsmith:guards — opt-in self-correction

Three harness-level mechanisms, each independently optional. modsmith never
turns them on by itself; this skill explains each one, asks which the user
wants, and installs only those into the **project's** `.claude/settings.json`
(never the user's global settings).

## What each guard buys

| Guard | Mechanism | What it catches |
|---|---|---|
| **Stop hook** | Claude Code runs your command whenever Claude tries to end its turn; exit 2 sends Claude back to work with the command's stderr as the reason. Enforced by the harness, not by the model remembering. | "Looks done" reported as done while the fast gate is red. The single most common autonomous-run failure. |
| **`/goal`** | A separate model checks a stated done-condition against the conversation after every turn and keeps Claude going until it is met. Session-scoped, no install. | Long runs that end on a progress summary with items still open. |
| **`/verify`** | Claude builds and launches the app and looks at the result. | Problems tests and typechecks miss: a block that renders black, a screen that opens empty. |

## Procedure

1. **Detect the fast gate.** Read `build.gradle` / `gradle.properties`.
   The Stop hook command must finish in well under a minute, so pick the
   cheapest gate that still means something: the project's static verifier
   plus unit tests (e.g. `./gradlew verifyMod test`), never a GameTest
   server boot. If the project has no gate under ~60s, say so and offer
   only `/goal` and `/verify`.
2. **Ask** (one AskUserQuestion, multi-select): Stop hook, `/goal` guidance
   in CLAUDE.md, `/verify` step in the project's documented loop.
3. **Stop hook, if chosen.** Merge into the project's `.claude/settings.json`
   (create it if absent; never overwrite other keys):

   ```json
   {
     "hooks": {
       "Stop": [
         { "hooks": [ { "type": "command",
             "command": "./gradlew -q verifyMod test 1>&2 || exit 2" } ] }
       ]
     }
   }
   ```

   Replace the gradle tasks with the detected fast gate. Tell the user
   the cap: after eight consecutive blocked stops with no tool call in
   between, Claude Code overrides the block and ends the turn
   (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` raises it).
4. **`/goal`, if chosen.** Add a short "Unattended runs" note to the
   project's CLAUDE.md: before leaving a run alone, set
   `/goal <the milestone's done-condition>` (tests named, PR opened, no
   must-fix review findings), and cap the run with `--max-turns` or a
   budget when headless.
5. **`/verify`, if chosen.** Add `/verify` to the project's documented
   Lane 1 order after the gate and before the PR, for any change that
   touches a visual surface (item, block, screen, renderer, structure).
6. **Prove it.** For the Stop hook: introduce a deliberate failing unit
   test on a scratch branch, ask Claude to finish, observe the block,
   revert. Report the observed behavior, not the intended one.

## Do not

- Put the Stop hook in `~/.claude/settings.json`; it would fire in every
  project, including non-Gradle ones.
- Use a GameTest run as the Stop gate; a 20-second server boot on every
  turn end makes the session unusable.
- Describe any guard as installed unless step 6 ran.
