# Decision menu {{N}} — pick what gets built next ({{date}})

<!-- Menu 1 is the Gear-1 → Gear-2 gate: it goes out with the triage
     doc, and nothing is implemented until the maintainer replies.
     Later menus carry discovered work. Number them. -->

Each item is scoped to run end-to-end through the dev workflow (branch →
red test → fix → PR; you merge). Batches are ordered by recommendation.
Reply with letters (e.g. "A, C, E") — or "A–E, keep going" to lift the
per-PR calibration pause once you trust the batting average.

---

## Your queue first *(delete if empty)*

Things only you can do; items below stall without them:

1. {{merge PR #N / cut release / rotate credential — exact command
   where possible}}

## A. {{batch title}} *(recommended first)*

- **Scope:** {{what it fixes or delivers, with triage refs in brackets
  — e.g. [1.1, 1.3]}}
- **Why this position:** {{impact/urgency in one or two lines}}
- **Effort:** {{half day / day / N sessions}} — {{N}} PR(s).
- **Risk:** {{what could go sideways; player-visible or not}}
- **Recommendation:** {{do it / do it after X / skip unless Y}}
- **Decision needed from you:** {{policy question that shapes the work,
  with the default the agent will use if you say only "A" — delete if
  none}}

## B. {{batch title}}

- **Scope:** …
- **Why this position:** …
- **Effort:** …
- **Risk:** …
- **Recommendation:** …

<!-- …continue C, D, E as needed. Writing-only batches (proposals,
     process write-ups) are valid menu items too — mark them "no code
     until you pick". -->

---

## Suggested order, if you just say "go"

1. {{sharpest correctness items first}}, then pause for your
   calibration check.
2. {{next batch(es)}}, pause.
3. {{compounding process/tooling items — early, they pay off across the
   whole window}} — then stop pausing per the ratchet rule.
4. {{the rest, batched}}.

## Open questions *(block nothing, shape work)*

- {{policy question + the default in use until answered}}

---

## Locked decisions *(append-only record)*

<!-- When the maintainer replies, record each decision here with the
     date and the exact disposition, then mirror it into the ledger's
     Status block. A decision that lives only in chat is lost to the
     next session. -->

- {{date}} — {{decision as stated, including any defaults accepted}}
