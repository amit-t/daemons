---
name: devin-routing
description: Check that a Devin task is scoped, sized and sent well before it runs, and say so once if it is not.
catalog-verified: 2026-09-25
review-by: 2026-12-15
---

# Routing policy for Devin Enterprise

You are reading a routing policy for work handed to Devin. Devin bills in
Agent Compute Units, and an ACU measures **agent effort**, not seat count and
not wall-clock time. What costs money is Devin working things out: planning,
exploring the codebase, running commands, and retrying after a failure.

That changes the order of the decisions. In a token-metered tool the first
question is which model. Here the first question is whether the task is cut
small enough to be worth sending at all.

**Scope, size, send.** In that order.

---

## When to run this check

Run it **once**, before a Devin session is created, on the first substantive
turn where a task is described.

Run it **again** only if the task materially changes shape.

Do **not** run it:

- on follow-up turns inside an already-running session
- when the user has already declined a suggestion in this session
- when the user has explicitly said the scope is deliberate

One note that lands is worth more than three that get ignored.

---

## Step 1: is it scoped?

A task is scoped when all four are true:

1. The goal is stated as an outcome, not a direction. "Return a JSON object
   with user count and average signup age from `/users/stats`" is scoped.
   "Add a user stats endpoint" is not.
2. There is a named way to check it: a test command, a build, a CI job, a
   verification script.
3. The files or modules in play are named, or are discoverable from one
   named entry point.
4. It is one task. Not a task and a cleanup and a question.

**If any of those fail, the answer is Ask mode, not a session.** Ask mode
explores the codebase and drafts the plan without touching a file, so being
vague there is free. Agent mode has no plan-approval gate: once it starts it
runs until it finishes or is stopped.

Failure patterns to name explicitly when you see them:

| Pattern | Why it costs | Say instead |
|---|---|---|
| Subjective goal ("make it cleaner") | Devin cannot judge aesthetics, so it guesses and rewrites | Ask for a named standard or an example to match |
| No completion criterion ("find and fix issues") | Nothing tells it when to stop | Name the check that ends the task |
| Architectural scope ("build the new service") | Too many decisions, not enough context | Take the decisions in Ask mode first |
| Several tasks in one prompt | The whole context stays live for all of them | One session each, run in parallel |

---

## Step 2: is it sized?

Devin scores every finished session into a band. Enterprise thresholds:

```yaml
bands:                       # enterprise ACUs; self-serve thresholds are 1/10 of these
  XS: "<= 20"                # a rename, a doc update, one small fix
  S:  "21 - 50"              # a contained bug fix with a test
  M:  "51 - 100"             # a feature inside one module
  L:  "101 - 200"            # a migration touching many files
  XL: "> 200"                # should have been split
target: "XS to M"
```

A well-sized slice is **under about ninety minutes of manual engineering
work**, junior in complexity, independently verifiable, and backwards
compatible so it can merge on its own. Migrations, refactors, modernisations
and technical-debt backlogs fit this shape. Complex net-new features do not,
and Cognition reports lower reliability for them at scale.

**Runaway signal:** repeated session limit hits mean the task is too complex.
The documented remedy is decomposition, not a larger budget.

**Parallelism note:** splitting into sub-sessions lowers wall-clock time and
raises total ACUs, because each sub-Devin gets its own virtual machine. Split
for clarity and verifiability, not to save money.

---

## Step 3: how to send it

### Where the controls exist

```yaml
devin_cli:
  model: yes                 # devin --model opus | /model <name> | agent.model in config
  effort: yes                # Alt+T (Opt+T on macOS) cycles the level
  fusion: yes                # /fusion picks lead, effort and sidekick
devin_desktop:
  model: yes                 # 100+ variants; the effort is part of the variant name
  effort: yes
devin_web:
  model: yes                 # agent selector
  effort: "SWE-2 only"       # Medium, High or Max; switch with the toggle by the input
slack:
  model: no
  effort: "speed only"       # !ultra and !fast
devin_api:
  model: no                  # inherits the org default
  effort: no
  cap: max_acu_limit         # the ONLY per-session ceiling Devin offers anywhere
```

### Which model

Prices below are what one task costs on Cognition's FrontierCode benchmark
(1.1 Extended, list prices, read 2026-09-25), with the benchmark score in
brackets. Compare cost per task: a model that is cheap per token can still be
expensive per task if it burns more tokens.

```yaml
routine:                     # renames, docs, formatting, small mechanical edits
  default: Adaptive          # $0.50 in / $2.00 out per 1M; Cognition's own router sends simple work to small models
  alternatives: [GPT-6 Luna Medium ($0.04 a task, 50.1), SWE-2 Medium ($0.30, 56.4)]

normal:                      # a fix a test can prove, a feature in one module
  default: Claude Opus 5.5 Medium       # $4 in / $20 out; $0.67 a task (65.3)
  small_fix: Claude Opus 5.5 Low        # $0.35 a task (60.3)
  fallback: GPT-6 Sol Medium            # $2 in / $10 out; $0.66 a task (57.1), if Opus 5.5 is not in the picker
  avoid: Claude Sonnet 5 Medium         # half Opus 5.5's token price, yet $3.16 a task (49.3)

hard:                        # unclear cause, incident work, design questions
  default: Claude Opus 5.5 Medium       # High for incidents and design questions: $0.90 a task (65.2)
  fallback: Claude Fable 5.1, same effort   # $10 in / $50 out; $2.68 a task at Medium (63.6)
  wide_work: Fusion                     # cross-module refactors, migrations, unattended runs
  lead: Claude Fable 5.1 Medium
  sidekick: SWE-2 Medium                # $0.75 in / $3.75 out until 2026-12-31, then $3 / $15
```

**Claude Opus 5.5 joined Devin's model table in the week of 22 September
2026**, at $4 input and $20 output per million tokens. If it has not reached
your picker yet, use the fallbacks above. Readers arriving from the Copilot
routing guide will find the same model at the top of both.

### Which effort

**Medium, unless you have evidence.** Every Claude and GPT model Cognition
marks as recommended in Devin is the Medium variant.

Effort never changes the token price. A higher level burns more tokens per
task at the same rate, and that is where the extra cost comes from. Claude
Opus 5.5, at $4 input and $20 output per million tokens throughout:

| Effort | Cost per task | Score | Against Medium |
|---|---|---|---|
| Low | $0.35 | 60.3 | 0.52 |
| Medium | $0.67 | 65.3 | 1.00 |
| High | $0.90 | 65.2 | 1.34 |
| XHigh | $1.86 | 63.5 | 2.78 |
| Max | $5.28 | 63.6 | 7.88 |

Across the eleven models measured below, Max costs 1.9 to 7.9 times Medium.
Extra levels buy real points on small models such as GPT-6 Luna and SWE-2; on
the frontier Claude models they mostly buy tokens. Fast variants double the
token price on top of whatever level you pick.

Numbers such as 80 beside a model in some pickers are **credit multipliers**:
per-message prices on legacy credit plans. Invenco is billed per token, so do
not budget with them.

### Fusion

Fusion runs a lead model that plans, reasons through the hard parts and
reviews the work, alongside a cheaper sidekick that does the mechanical
implementation. Each model bills at its own token rate, so the lead's
thinking level moves only the lead's share of the cost.

Measured against the lead model running alone:

| Where measured | Lead alone | Fusion | Cost |
|---|---|---|---|
| FrontierCode | Fable 5.1 Medium: $2.68 (63.6) | with SWE-2: $1.67 (63.5) | -38% |
| FrontierCode | GPT-6 Astra High: $2.62 (63.1) | with SWE-2 Medium: $2.34 (63.4) | -11% |
| FrontierCode | GPT-6 Astra High: $2.62 (63.1) | with GPT-5.6 Luna High: $2.39 (62.0) | -9% |
| Artificial Analysis | Fable 5.1 Max: $12.39 (62.2) | Fable 5.1 XHigh with SWE-2 Medium: $7.90 (61.7) | -36% |
| Artificial Analysis | GPT-6 Astra Max: $7.47 (61.6) | Astra XHigh with SWE-2 Medium: $4.54 (58.9) | -39% |

The Fable lead level on FrontierCode is inferred from the matching solo run in
Cognition's post. On Artificial Analysis the Fusion lead ran at XHigh against
solo models at Max, so part of that saving comes from the lower level.

Artificial Analysis Coding Agent Index v1.5, the one independent harness
comparison:

| Harness and model | Index | Cost per task |
|---|---|---|
| Claude Code, Opus 5.5 max | 66.0 | $13.04 |
| Claude Code, Fable 5.1 max | 62.2 | $12.39 |
| **Devin Fusion, Fable 5.1 XHigh with SWE-2 Medium** | **61.7** | **$7.90** |
| Codex, GPT-6 Astra max | 61.6 | $7.47 |
| Claude Code, Opus 5 max | 59.7 | $10.79 |
| **Devin Fusion, GPT-6 Astra XHigh with SWE-2 Medium** | **58.9** | **$4.54** |
| Codex, GPT-6 Sol max | 56.7 | $2.99 |

Those dollars are API token prices, so read the ratios. The catch: Opus 5.5 at
Medium, running alone, costs $0.67 a task on FrontierCode, less than either
pairing, and no Fusion run with an Opus 5.5 lead is published yet. Use Fusion
for wide, multi-file work where a cheap sidekick carries most of the edits.

---

## Step 4: when to speak, and how

| Condition | Action |
|---|---|
| The task fails two or more scope tests | Speak. Recommend Ask mode first |
| The task fails one scope test and names no verification | Speak |
| The task bundles independent pieces of work | Speak. Recommend one session per piece |
| The task looks like L or XL and is not a migration | Speak |
| The effort level is High, XHigh or Max without a stated reason | Speak once |
| A session is being created through the API with no `max_acu_limit` | Speak |
| The task is scoped, sized and on Medium | Stay quiet and get on with it |

Say it in four lines or fewer, above your normal answer, then help anyway.
Never hold work hostage to a routing note.

```
Scope check: this reads as an L-sized task: it spans several modules and
names no test that would prove it. Two suggestions. Take it through Ask mode
first, which costs a fraction of a session and cannot edit code. Then split
it into slices that each have a check, and run those in parallel.
Say "go" and I will run it as written.
```

---

## What costs money, and what does not

Cognition's own list. Five of the seven drivers are settled before the session
starts.

**Billed:** planning and context gathering · reading and searching the
codebase · writing code and running commands · browser actions and tool calls
· retries after a failure · virtual machine time and bandwidth.

**Free:** waiting for your reply · waiting for the test suite · cloning and
setting up repositories · a sleeping session, after 30 idle minutes.

So leaving a session open costs nothing, and leaving it working costs
everything. Windows sessions consume about 9% more than the same work on
Linux; macOS currently matches Linux.

**Consumption rises with:** task complexity · vague prompts · large context or
codebase · number of files touched · session runtime · conversation length ·
frequent back-and-forth. Only the first and the fifth are outside your control.

---

## Setup is a cost control

The published case study: one feature prompt cost **42 ACUs** where **12**
was achievable, a 70% reduction. None of it came from a cheaper model.

1. Devin read 23 files looking for a pagination helper that already existed.
   A skill entry naming it would have stopped the search.
2. It chose cursor-based pagination, hit tests written for offset-based, and
   rewrote the work. A plan agreed in Ask mode would have caught it.
3. `npm install` failed twice on a missing `.npmrc` for the private registry,
   and Devin retried with workarounds. About 3 ACUs, spent on config.

So, in order of payback:

| Do this once | Stops paying for |
|---|---|
| Index the repo, fix the build, save a blueprint or snapshot | Devin fighting your environment, every session |
| Write Skills for conventions, locations and known traps | Rediscovery of things a colleague would have told it |
| Write Playbooks for procedures you repeat | Re-explaining the same sequence |
| Put an `AGENTS.md` at the repo root | Devin hunting for your test command |

**Knowledge was deprecated on 18 September 2026** and existing entries are
migrating to Skills in Plugins. Write new context as Skills.

---

## Surfaces

| Surface | Reach for it when | What it costs |
|---|---|---|
| DeepWiki | Meeting an unfamiliar or legacy repo | Free at low effort; enterprise is locked there |
| Ask Devin | Finding things, scoping, drafting the prompt | Cheap. It cannot edit code |
| Devin session | Writing the code, opening the PR | The main meter |
| Devin Review | Triaging pull requests at volume | Same pool, but outside per-user caps |
| Devin CLI | Local work where you want the model dial | Tokens at the model's price |
| Devin Desktop | IDE work, widest model catalogue | Tokens at the model's price |
| Sub-Devins | Independent slices to run in parallel | Wall clock down, total ACUs up |
| Automations | Scheduled or event-driven work | Set `max_acu_limit` |

Devin Wiki effort costs: Low is free, Medium is about 5 to 10 ACUs per wiki,
High about 20 to 40. Enterprise organisations are locked to Low.

---

## Governance, and the gap in it

- **Usage tiers** give each member an individual monthly ACU allocation. A
  tier is not a shared pot.
- **Hitting a cap blocks work on every surface at once**, cloud and local.
  Warnings appear around two thirds; members can request more in the app.
- **Organization limits** are a second, independent ceiling.
- **Session Insights** reports the ACU cost, size band and message count of
  every finished session. Read it for a week and you will calibrate fast.
- **Devin Coach** flags five wasteful prompt patterns before they run: a large
  request with no approach, non-work usage, an oversized model for a simple
  task, an off-topic follow-up, and bundled independent tasks.
- **Nothing caps a single session.** All limits are monthly. One runaway
  session can take a large share of a month before anything stops it. The only
  per-session ceiling anywhere is `max_acu_limit` on API-created sessions.
- **Devin Review sits outside per-user limits**, so a heavy reviewer will not
  be stopped by their own cap. The per-PR auto-review spend limit defaults to
  no limit.

---

## Reading Cognition's benchmarks

SWE-2 arrived on 10 September 2026, post-trained from Kimi K3.

**Where it wins:** FrontierCode 1.1 Main 50.0% at $1.18 per run, against
Claude Fable 5.1 at 50.9% for $3.28. DeepSWE 1.1 73.0%. It takes 58% fewer
turns than SWE-1.7 and makes its first real edit after 18 steps rather than 48.

**Where it does not:** Terminal-Bench 4 27.3% against Fable 5.1's 55.8%, by
Cognition's own reporting. It also spends 72.8k output tokens per FrontierCode
run where Fable 5.1 spends 26.1k, so it is cheap per token rather than thrifty
with them.

**Who owns the scoreboard:** FrontierCode is built, graded and hosted by
Cognition, and SWE-2 runs there on Cognition's own harness. SWE-2 and Devin do
not appear on SWE-bench, SWE-bench Pro or the official Terminal-Bench board at
all. The single independent corroboration is Artificial Analysis, and it does
support the Fusion cost claim.

Practical reading: use SWE-2 as a sidekick, where its job is mechanical and a
lead model checks the work. On enterprise plans it costs $0.75 input and $3.75
output per million tokens until 31 December 2026, 75% off its $3 and $15 list
price, so this quarter is the cheap window to form your own view. It is free
only on self-serve plans, until 15 October.

---

## Price by thinking level

**How Devin bills us.** On Invenco's enterprise plan, local work in Devin
Desktop and the CLI is metered in ACUs converted from tokens at the per-token
prices on Cognition's models page (the Enterprise, ACUs tab). Cloud sessions
add VM and compute time on top. A thinking level has no price of its own: it
changes how many tokens a task burns. So the price that matters is the cost of
a task at each level, which Cognition measures on FrontierCode.

Cost of one FrontierCode task by thinking level, USD at list price, with the
score in brackets. Rows sorted by the Medium column. Token prices are USD per
million, input then output. `n/a` means the level is not offered or not
measured.

| Model | Tokens in / out | Low | Medium | High | XHigh | Max |
|---|---|---|---|---|---|---|
| GPT-6 Luna | 0.10 / 0.50 | $0.02 (39.1) | $0.04 (50.1) | $0.05 (51.3) | $0.06 (51.4) | $0.08 (56.1) |
| GPT-5.6 Luna | 0.20 / 1.20 | $0.06 (29.0) | $0.12 (41.2) | $0.20 (50.5) | $0.26 (54.5) | $0.31 (55.1) |
| SWE-2 | 0.75 / 3.75 | n/a | $0.30 (56.4) | $0.64 (60.1) | n/a | $0.94 (62.5) |
| GPT-6 Sol | 2 / 10 | $0.38 (50.5) | $0.66 (57.1) | $0.87 (59.6) | $1.11 (59.1) | $1.66 (60.7) |
| Claude Opus 5.5 | 4 / 20 | $0.35 (60.3) | $0.67 (65.3) | $0.90 (65.2) | $1.86 (63.5) | $5.28 (63.6) |
| GPT-6 Astra | 10 / 50 | $1.50 (57.4) | $2.10 (60.3) | $2.62 (63.1) | $2.86 (62.1) | $3.93 (64.5) |
| Claude Fable 5.1 | 10 / 50 | $1.94 (61.6) | $2.68 (63.6) | $4.28 (62.7) | $7.70 (61.4) | $10.72 (62.0) |
| Claude Opus 4.7 | 5 / 25 | $2.11 (43.6) | $2.73 (44.8) | $4.21 (51.1) | $5.77 (51.4) | $7.61 (53.9) |
| Claude Opus 4.8 | 5 / 25 | $2.27 (50.8) | $3.06 (55.4) | $3.54 (55.6) | $5.58 (59.5) | $8.05 (59.6) |
| Claude Sonnet 5 | 2 / 10 | $2.03 (44.5) | $3.16 (49.3) | $4.97 (52.7) | $8.23 (56.2) | $14.09 (54.9) |
| Claude Opus 5 | 5 / 25 | $2.15 (55.8) | $3.51 (63.6) | $5.84 (58.5) | $7.44 (56.9) | $9.68 (58.9) |
| Fusion: Fable 5.1 + SWE-2 | lead + SWE-2 | n/a | $1.67 (63.5) | n/a | n/a | n/a |
| Fusion: GPT-6 Astra + SWE-2 Medium | lead + SWE-2 | n/a | n/a | $2.34 (63.4) | n/a | n/a |

GPT-5.6 Sol is left out because the benchmark prices it at a promotional rate
the enterprise plan does not get; on our rates ($4 / $20) it costs more than
GPT-6 Sol at every level.

**Cheapest to costliest**, today's models and the Fusion pairings, by cost per
task:

- **Under $0.10:** GPT-6 Luna at every level ($0.02 to $0.08)
- **$0.10 to $0.49:** SWE-2 Medium $0.30, Opus 5.5 Low $0.35, GPT-6 Sol Low $0.38
- **$0.50 to $0.99:** SWE-2 High $0.64, GPT-6 Sol Medium $0.66, Opus 5.5 Medium $0.67, GPT-6 Sol High $0.87, Opus 5.5 High $0.90, SWE-2 Max $0.94
- **$1.00 to $2.49:** GPT-6 Sol XHigh $1.11, GPT-6 Astra Low $1.50, GPT-6 Sol Max $1.66, Fusion Fable 5.1 + SWE-2 $1.67, Opus 5.5 XHigh $1.86, Fable 5.1 Low $1.94, Sonnet 5 Low $2.03, GPT-6 Astra Medium $2.10, Opus 5 Low $2.15, Fusion Astra High + SWE-2 $2.34, Fusion Astra High + GPT-5.6 Luna $2.39
- **$2.50 to $4.99:** GPT-6 Astra High $2.62, Fable 5.1 Medium $2.68, GPT-6 Astra XHigh $2.86, Sonnet 5 Medium $3.16, Opus 5 Medium $3.51, GPT-6 Astra Max $3.93, Fable 5.1 High $4.28, Sonnet 5 High $4.97
- **$5 and up:** Opus 5.5 Max $5.28, Opus 5 High $5.84, Opus 5 XHigh $7.44, Fable 5.1 XHigh $7.70, Sonnet 5 XHigh $8.23, Opus 5 Max $9.68, Fable 5.1 Max $10.72, Sonnet 5 Max $14.09

Token prices for the rest of the catalogue, enterprise plan, cheapest to
costliest on output. Effort variants share their model's price; Fast variants
cost twice as much.

| Model | Input | Output |
|---|---|---|
| Fast Arena | 0.10 | 0.50 |
| GPT-6 Luna | 0.10 | 0.50 |
| GPT-5.6 Luna | 0.20 | 1.20 |
| Grok Code Fast 1 | 0.20 | 1.50 |
| Adaptive | 0.50 | 2.00 |
| SWE-2 (75% off until 2026-12-31) | 0.75 | 3.75 |
| DeepSeek V4 Pro | 1.32 | 3.96 |
| GLM-5.2, GLM-5.3 | 1.40 | 4.40 |
| Claude Haiku 4.5 | 1.00 | 5.00 |
| Hybrid Arena | 1.00 | 5.00 |
| Grok 4.5, Grok 4.6 | 2.00 | 6.00 |
| Gemini 3.6 / 3.7 / 3.8 Flash | 1.50 | 7.50 |
| Gemini 3.5 Flash | 1.50 | 9.00 |
| Claude Sonnet 5 | 2.00 | 10.00 |
| GPT-6 Sol | 2.00 | 10.00 |
| GPT-5.6 Terra | 2.00 | 12.00 |
| Kimi K3 | 3.00 | 15.00 |
| Frontier Arena | 3.00 | 15.00 |
| Claude Sonnet 4.6 | 3.00 | 15.00 |
| GPT-5.6 Sol | 4.00 | 20.00 |
| Claude Opus 5.5 | 4.00 | 20.00 |
| Claude Opus 4.7 / 4.8 / 5 | 5.00 | 25.00 |
| GPT-6 Astra | 10.00 | 50.00 |
| Claude Fable 5 / 5.1 | 10.00 | 50.00 |

GPT models bill the whole request at a higher long-context rate once the
prompt passes 272K tokens; GPT-6 Astra goes to $20 input and $75 output.
Cognition publishes no dollar value per ACU anywhere; the rate is set in each
customer's order form. Gemini Flash is at full list price on the enterprise
plan, where Copilot is running it at half price until the end of 2026.

---

## Fusion cost glossary

| Term | Meaning |
|---|---|
| Fusion | Two agents on one task: a frontier lead and a cheaper sidekick, each billed at its own token rate. Not offered on credit plans. |
| Lead | Owns the plan, settles ambiguity and reviews the work. Cognition's published runs use Fable 5.1 and GPT-6 Astra. |
| Sidekick | Explores code, makes the edits, runs the tests and reports back. SWE-2 is Cognition's recommended choice. |
| Thinking level | How long a model reasons before it answers, from Low to Max. The token price stays put while the token count grows. |
| Fast Mode | Faster variants of the same models at about twice the token rate. |
| Token rate | Dollars per million input and output tokens. On our plan Devin turns local agent tokens into ACUs at these rates. |
| Cache read | Context the model has already seen, billed at a small fraction of the input rate. Switching model mid-task throws it away. |
| Cost per task | What finishing one task costs. The number to compare, because a model that uses fewer tokens can cost less overall. |
| ACU | Devin's billing unit. Invenco buys 24,000 a month; the dollar value of one ACU sits in the order form. |
| Credit multiplier | The per-message price on legacy credit plans, such as 80 for Opus 5.5 Medium. Our plan pays per token instead. |
| `/session-stats` | CLI command, also `/stats`, showing tokens, cost by model and the estimated Fusion saving for a session. |
| Long-context rate | GPT models bill the whole request at a higher rate once the prompt passes 272K tokens. |

---

## Staleness

Figures verified **2026-09-23**; model prices, per-level costs and benchmark
tables re-checked **2026-09-25**. Cognition ships weekly and the rate card
moves with it. What will go stale first: the model list and its prices, the
per-level FrontierCode costs, SWE-2's discount (ends 31 December 2026), and
the Knowledge-to-Skills migration.

What will not go stale: an ACU measures effort, Ask mode is free to be vague
in, a session with no verification criterion is a session that will overrun,
and nothing caps a single session.

Sources: Cognition documentation (usage and billing, enterprise billing,
session insights, usage policies, Devin Coach, DeepWiki, Devin Review, CLI,
Fusion, the AI Models page with its Enterprise and legacy credit tabs, 2026
release notes); Cognition's SWE-2 post and "Introducing Fusion in Devin
Desktop & CLI" (11 September 2026); Artificial Analysis Coding Agent Index
v1.5; the FrontierCode leaderboard, 1.1 Main and Extended at every reasoning
level. Read 2026-09-23, with prices and benchmarks re-read 2026-09-25.
