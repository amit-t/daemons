# DAG Forecast-Safe Allocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop DAG Borrow from insta-blocking donors (forecast-blind floor cuts), let boost/seed flows spend the enterprise forecast surplus instead of forcing zero-sum, and surface org-gate overcommit — then run a full-team `dag set-limits` reset.

**Architecture:** All allocation math lives in `lib/*.jq` planners (hard rule 1: jq output is authoritative). Fixes land in the planners (safe defaults + input validation, so a sloppy session cannot silently disable forecasts), in `lib/dashboard.jq` (org-gate overcommit warning), and in the playbooks that drive them. No `bin/dag` changes.

**Tech Stack:** jq programs + zsh test harness (`test/harness.zsh`, `assert_contains`), playbook markdown, Devin API v3/v3beta1 (runtime only, Phase B).

**Spec:** The `/goal` text of 2026-09-02 (this plan's §Context is the distilled spec).

## Global Constraints

- Hard rule 11 unchanged: recipient direct headroom 250 default / 500 hard max, never above.
- Hard rule 2 unchanged: every API write behind `CONFIRM DAG WRITE`.
- jq programs keep safe built-in defaults as the backstop; playbooks pass explicit values.
- Legacy planner behavior stays reachable via explicit inputs (tests prove both paths).
- Repo rule: zsh only, `zsh -n` validation, README updated with behavior changes, commit + push when verified.
- Invenco `ai-daemons` pins this daemon by SHA-256 — these edits break inv.dag parity until a reviewed re-pin (out of scope; note in final report).

---

## Context — what broke and why

**Incident:** user cap 150 → became Borrow donor → cap cut to 50 → immediately blocked.

**Root causes (verified in code):**

1. **Silent forecast disable.** `borrow-caps.jq:93` `(.days_left // 0)` and `boost-plan.jq:38` `(.days_left // $r.days_left // 0)`: omit `days_left` and every `run_rate × days_left` projection multiplies to 0 — the forecast floor collapses to `consumed × 1.1` with **no warning**.
2. **`run_rate` optional, silently.** A donor without `run_rate` gets a consumed-only floor. Idle-last-week donors (the prime donor candidates) have tiny consumed → tiny floor → deep cut; the moment they resume work they hit the cap.
3. **No absolute donor floor in `borrow-caps.jq`.** `donor_floor_min` defaults **0** and no playbook passes it. `boost-plan.jq` has `min_donor_cap_after` 50, but 50 is a *cap* floor, not a *headroom* floor: a donor consumed 45 legally lands at cap 50 → 5 ACUs from blocked. Matches the incident exactly (`ceil(45×1.1)=50`).
4. **Org gate fights user caps.** Local Agent enforces two independent gates (per-user cap AND billing-org aggregate cap). When org cap < Σ member user caps, users with personal headroom get blocked by the org gate. Nothing detects or reports this today.
5. **Zero-sum is too rigid when the org is projected UNDER.** Dashboard says enterprise projected 3,546 ACUs under pool, yet boost refuses +150 as "over budget". Unused headroom expires at cycle end — no reason to hoard it.

---

## Decisions (comment inline; recommendations pre-picked)

| # | Decision | Recommendation |
|---|----------|----------------|
| D1 | Funding order when forecast surplus exists | **Forecast-first**: fund boosts from enterprise forecast headroom before cutting any donor. Donors only cover what forecast headroom can't. Spares donors entirely while org is UNDER. |
| D2 | Forecast utilization factor | **0.5 default** (spend at most half the projected surplus; projection is linear and noisy). Up to 1.0 only on explicit in-session request. |
| D3 | Donors without `run_rate` | **Excluded from the donor pool** (`require_forecast: true` default), listed with reason. `require_forecast: false` restores consumed-only floors — explicit opt-in when Windsurf/daily data is genuinely unavailable. |
| D4 | Org gate fix | **Detect + sync, don't auto-write**: dashboard warns on `Σ member user caps > org local cap`; every user-cap write playbook ends with an org-gate check offering a separate org-cap PATCH preview (own `CONFIRM DAG WRITE`). Alternative (your call): clear org local caps entirely and govern per-user only. |
| D5 | Team reset command | **`dag set-limits` full re-prorate** (Phase B). `set-limits-new` only seeds uncapped users — it cannot reset existing caps. Full mode also wipes the donor record (everyone re-based = all donors made whole). |
| D6 | New donor floor | `floor = max(projected-consumption floor, ceil(consumed) + min_donor_headroom, min_donor_cap_after)` with **`min_donor_headroom` 25** and **`min_donor_cap_after` 50** defaults. No donor ever left within 25 ACUs of blocked. |

---

## Phase A — code (Tasks 1–7)

### Task 1: borrow-caps.jq — forecast-safe donor floors

**Files:**
- Modify: `claude/devin-acu-governor/lib/borrow-caps.jq`
- Test: `claude/devin-acu-governor/test/borrow-caps.test.zsh`

**Interfaces:**
- Produces new inputs: `min_donor_cap_after` (default 50, alias of legacy `donor_floor_min`), `min_donor_headroom` (default 25), `require_forecast` (default true). New error when donor `run_rate` present but `days_left` key absent. New output fields: `min_donor_cap_after`, `min_donor_headroom`, `require_forecast`; excluded no-forecast donors appear in `donors_excluded` with reason `no_run_rate_forecast`.
- Consumes: nothing new.

- [ ] **Step 1: Write failing tests** — append to `test/borrow-caps.test.zsh` (before the harness summary line, matching existing style):

```zsh
# N1. Safe defaults: donor consumed 45 is NOT cut to 50. Floor =
#     max(ceil(45*1.1)=50, ceil(45)+25=70, 50) = 70. cap 150 -> avail 80.
#     require_forecast off (no run_rate data in this fixture).
out=$(run_jq '{"require_forecast":false,"recipients":[{"email":"r1@x","consumed":10}],
  "donors":[{"email":"d1@x","cap":150,"consumed":45}]}')
assert_contains "N1 floor keeps 25 headroom" "$out" '"cap_after":70'
assert_contains "N1 min_donor_headroom out" "$out" '"min_donor_headroom":25'
assert_contains "N1 min_donor_cap_after out" "$out" '"min_donor_cap_after":50'

# N2. Absolute floor: idle donor (consumed 0) never cut below 50.
#     floor = max(0, 0+25, 50) = 50. cap 300 -> avail 250.
out=$(run_jq '{"require_forecast":false,"recipients":[{"email":"r1@x","consumed":200}],
  "donors":[{"email":"d1@x","cap":300,"consumed":0}]}')
assert_contains "N2 floor 50" "$out" '"cap_after":50'

# N3. days_left guard: donor run_rate without days_left key = hard error.
out=$(run_jq '{"recipients":[{"email":"r1@x","consumed":10}],
  "donors":[{"email":"d1@x","cap":300,"consumed":20,"run_rate":5}]}')
assert_contains "N3 error" "$out" 'days_left missing while donor run_rate supplied'

# N4. require_forecast default: donor without run_rate excluded, listed with reason.
out=$(run_jq '{"days_left":10,"recipients":[{"email":"r1@x","consumed":10}],
  "donors":[{"email":"d-blind@x","cap":300,"consumed":20},
            {"email":"d-fc@x","cap":300,"consumed":20,"run_rate":0}]}')
assert_contains "N4 excluded" "$out" '"email":"d-blind@x"'
assert_contains "N4 reason" "$out" 'no_run_rate_forecast'
assert_contains "N4 warn" "$out" 'excluded: no run_rate forecast'
assert_contains "N4 fc donor used" "$out" '"email":"d-fc@x","cap_before":300'

# N5. Forecast floor still binds: run_rate 10 x days_left 10 on consumed 20
#     -> proj floor ceil((20+100)*1.1)=132 > consumed floor. cap 300 -> avail 168.
out=$(run_jq '{"days_left":10,"recipients":[{"email":"r1@x","consumed":150}],
  "donors":[{"email":"d1@x","cap":300,"consumed":20,"run_rate":10}]}')
assert_contains "N5 proj floor" "$out" '"cap_after":132'
```

- [ ] **Step 2: Run to verify failure**

Run: `zsh claude/devin-acu-governor/test/borrow-caps.test.zsh`
Expected: N1–N5 FAIL (legacy defaults 0/absent behavior), A–M still PASS.

- [ ] **Step 3: Implement.** In `borrow-caps.jq`:

Replace the parameter block (current lines 90–93):

```jq
(.donor_buffer // 0.10) as $dbuf
| (.max_headroom // 500) as $max_headroom
| (.min_donor_cap_after // .donor_floor_min // 50) as $floor_min
| (.min_donor_headroom // 25) as $min_headroom
| (if has("require_forecast") then .require_forecast else true end) as $require_forecast
| (has("days_left")) as $has_days
| (.days_left // 0) as $days_left
```

Replace the donor selection (current lines 97, 99) so no-forecast donors are excluded with a reason:

```jq
| ([ $all_donors[] | select(eligible) ]) as $donors_all
| ([ $donors_all[] | select(($require_forecast | not) or ((.run_rate // null) != null)) ]) as $donors
| ([ $donors_all[] | select($require_forecast and ((.run_rate // null) == null))
     | excluded_donor_row | .reasons = ["no_run_rate_forecast"] ]) as $donors_noforecast
| (([ $all_donors[] | select(eligible | not) | excluded_donor_row ]) + $donors_noforecast) as $donors_excluded
```

Add the days_left guard as a new `elif` branch after the existing `elif $n == 0` branch:

```jq
  elif ($has_days | not) and ([ $donors[] | select((.run_rate // null) != null) ] | length) > 0 then
    {error: "days_left missing while donor run_rate supplied — forecast floors would collapse to consumed-only; pass days_left"}
```

Replace the floor line (current line 121):

```jq
       | ([$proj_floor, ((.consumed | ceil) + $min_headroom), $floor_min] | max) as $floor
```

In the output object: rename the reported keys — replace `donor_floor_min: $floor_min,` with:

```jq
        min_donor_cap_after: $floor_min,
        min_donor_headroom: $min_headroom,
        require_forecast: $require_forecast,
```

Append to `warnings`:

```jq
          + (if ($donors_noforecast | length) > 0
               then ["\($donors_noforecast | length) donor(s) excluded: no run_rate forecast (require_forecast). Pass run_rate, or require_forecast:false to accept consumed-only floors: \([$donors_noforecast[].email] | join(", "))"] else [] end)
```

Also update the file's header comment block (input/output docs) to the new fields.

- [ ] **Step 4: Fix legacy fixtures.** Tests A–M were written against defaults 0/absent. Prepend `"min_donor_cap_after":0,"min_donor_headroom":0,"require_forecast":false,` inside the JSON object of **every existing** `run_jq '...'` call (A through M), leaving their arithmetic and assertions untouched. (Any existing test that already passes donor `run_rate` must also carry a `days_left` key — add `"days_left":0` if missing.)

- [ ] **Step 5: Run tests**

Run: `zsh claude/devin-acu-governor/test/borrow-caps.test.zsh`
Expected: all PASS. Also `zsh -n claude/devin-acu-governor/test/borrow-caps.test.zsh`.

- [ ] **Step 6: Commit**

```bash
git add claude/devin-acu-governor/lib/borrow-caps.jq claude/devin-acu-governor/test/borrow-caps.test.zsh
git commit -m "fix(dag): forecast-safe donor floors in borrow-caps (min headroom 25, abs floor 50, days_left guard, require_forecast)"
```

### Task 2: boost-plan.jq — forecast-safe donor floors

**Files:**
- Modify: `claude/devin-acu-governor/lib/boost-plan.jq`
- Test: `claude/devin-acu-governor/test/boost-plan.test.zsh`

**Interfaces:**
- Produces new inputs: `min_donor_headroom` (default 25), `require_forecast` (default true); same days_left guard (satisfied by top-level `days_left` **or** `recipient.days_left`). New output: `min_donor_headroom`, `require_forecast`, `donors_excluded_no_forecast` (emails), error object on guard trip.
- Consumes: nothing from Task 1 (independent file, same conventions).

- [ ] **Step 1: Write failing tests** — append to `test/boost-plan.test.zsh` (fixture style mirrors that file's existing `run_jq` helper; adapt the helper name if it differs):

```zsh
# N1. Donor headroom floor: donor consumed 45, cap 150, share 100.
#     floor = max(ceil(45+0.1*100)=55, ceil(45)+25=70, 50) = 70 -> avail 80, not 95.
#     delta_override 200 > avail, so the donor is drained exactly to its floor (70).
out=$(run_jq '{"pool":1000,"share":100,"require_forecast":false,
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":5,"days_left":10,"delta_override":200},
  "donors":[{"email":"d1@x","cap":150,"consumed":45}]}')
assert_contains "N1 floor 70" "$out" '"cap_after":70'
assert_contains "N1 min_donor_headroom" "$out" '"min_donor_headroom":25'

# N2. days_left guard: donor run_rate present, no days_left anywhere = error.
out=$(run_jq '{"pool":1000,"share":100,
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":5},
  "donors":[{"email":"d1@x","cap":150,"consumed":10,"run_rate":2}]}')
assert_contains "N2 error" "$out" 'days_left missing while donor run_rate supplied'

# N3. require_forecast default: run_rate-less donor excluded and named.
out=$(run_jq '{"pool":1000,"share":100,"days_left":10,
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":5,"days_left":10},
  "donors":[{"email":"d-blind@x","cap":500,"consumed":0},
            {"email":"d-fc@x","cap":500,"consumed":0,"run_rate":0}]}')
assert_contains "N3 excluded list" "$out" '"donors_excluded_no_forecast":["d-blind@x"]'
assert_contains "N3 warn" "$out" 'excluded: no run_rate forecast'
assert_contains "N3 fc donor gives" "$out" '"email":"d-fc@x"'
```

- [ ] **Step 2: Run to verify failure**

Run: `zsh claude/devin-acu-governor/test/boost-plan.test.zsh` — N1–N3 FAIL, legacy pass.

- [ ] **Step 3: Implement.** In `boost-plan.jq`:

Extend the parameter block (after line 37):

```jq
| (.min_donor_headroom // 25) as $min_headroom
| (if has("require_forecast") then .require_forecast else true end) as $require_forecast
| ((has("days_left")) or ($r | has("days_left"))) as $has_days
```

Wrap the whole plan in the guard — immediately after the parameter block insert:

```jq
| if ($has_days | not) and any(.donors[]; (.run_rate // null) != null) then
    {error: "days_left missing while donor run_rate supplied — forecast floors would collapse to consumed-only; pass days_left"}
  else
```

(and close with `end` at file end; re-indent the existing pipeline body).

Split the donor pool (replace the `$pool_cands` binding intro):

```jq
| ([ .donors[] | select($require_forecast and ((.run_rate // null) == null)) | .email ]) as $no_fc_donors
| ([ .donors[]
     | select(($require_forecast | not) or ((.run_rate // null) != null))
     | ([((.consumed + ($dbuf * $share)) | ceil), ((.consumed | ceil) + $min_headroom), $mincap] | max) as $base_floor
```

(the `run_rate`/`$proj_floor` lines and everything downstream stay as-is).

Output additions inside the result object:

```jq
    min_donor_headroom: $min_headroom,
    require_forecast: $require_forecast,
    donors_excluded_no_forecast: $no_fc_donors,
```

Warnings addition:

```jq
      + (if ($no_fc_donors | length) > 0
           then ["\($no_fc_donors | length) donor(s) excluded: no run_rate forecast (require_forecast). Pass run_rate, or require_forecast:false to accept consumed-only floors: \($no_fc_donors | join(", "))"]
           else [] end)
```

Update the header comment docs.

- [ ] **Step 4: Fix legacy fixtures.** Add `"min_donor_headroom":0,"require_forecast":false` to every existing `run_jq` input in `boost-plan.test.zsh`; any fixture with donor `run_rate` but no `days_left` key anywhere gets top-level `"days_left":0`.

- [ ] **Step 5: Run tests**

Run: `zsh claude/devin-acu-governor/test/boost-plan.test.zsh` — all PASS; `zsh -n` clean.

- [ ] **Step 6: Commit**

```bash
git add claude/devin-acu-governor/lib/boost-plan.jq claude/devin-acu-governor/test/boost-plan.test.zsh
git commit -m "fix(dag): forecast-safe donor floors in boost-plan (min headroom 25, days_left guard, require_forecast)"
```

### Task 3: boost-plan.jq — forecast-headroom funding

**Files:**
- Modify: `claude/devin-acu-governor/lib/boost-plan.jq`
- Test: `claude/devin-acu-governor/test/boost-plan.test.zsh`

**Interfaces:**
- Produces new optional input: `"forecast": {"pool": <int>, "projected_cycle_total": <number>, "utilization": <number=0.5, clamped 0..1>}`. New outputs: `forecast_headroom`, `forecast_funded`, `donor_funded`, `zero_sum` (false when `forecast_funded > 0`); `sum_after == sum_before + forecast_funded`. Error `{error: "forecast requires pool and projected_cycle_total"}` on malformed forecast.
- Consumes: Task 2's guard structure (the added `else … end` wrapper).

- [ ] **Step 1: Write failing tests:**

```zsh
# F1. Forecast-first: enterprise projected 3546 under pool, utilization 0.5
#     -> forecast_headroom 1773 fully funds delta; NO donor is cut.
out=$(run_jq '{"pool":24000,"share":100,"days_left":10,"require_forecast":false,
  "forecast":{"pool":24000,"projected_cycle_total":20454},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":8,"days_left":10,"delta_override":150},
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "F1 headroom" "$out" '"forecast_headroom":1773'
assert_contains "F1 funded" "$out" '"forecast_funded":150'
assert_contains "F1 no donor cut" "$out" '"takes":[]'
assert_contains "F1 not zero-sum" "$out" '"zero_sum":false'
assert_contains "F1 recipient" "$out" '"cap_after":250'
assert_contains "F1 warn" "$out" 'funded from enterprise forecast headroom'

# F2. Split funding: forecast covers 40, donors the rest.
#     utilization 0.5 on (1000-920)=80 -> headroom 40; delta 100 -> donors give 60.
out=$(run_jq '{"pool":1000,"share":100,"days_left":10,"require_forecast":false,"min_donor_headroom":0,
  "forecast":{"pool":1000,"projected_cycle_total":920},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":1,"days_left":10,"delta_override":100},
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "F2 headroom" "$out" '"forecast_headroom":40'
assert_contains "F2 fc funded" "$out" '"forecast_funded":40'
assert_contains "F2 donor funded" "$out" '"donor_funded":60'
assert_contains "F2 donor take" "$out" '"given":60'

# F3. Projected OVER pool: headroom 0, behavior identical to zero-sum.
out=$(run_jq '{"pool":1000,"share":100,"days_left":10,"require_forecast":false,"min_donor_headroom":0,
  "forecast":{"pool":1000,"projected_cycle_total":1200},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":1,"days_left":10,"delta_override":50},
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "F3 headroom 0" "$out" '"forecast_headroom":0'
assert_contains "F3 zero-sum" "$out" '"zero_sum":true'

# F4. Malformed forecast input.
out=$(run_jq '{"pool":1000,"share":100,"forecast":{"pool":1000},
  "recipient":{"email":"r@x","cap":100,"consumed":90,"run_rate":1,"days_left":10},"donors":[]}')
assert_contains "F4 error" "$out" '"error":"forecast requires pool and projected_cycle_total"'
```

- [ ] **Step 2: Run to verify failure** — F1–F4 FAIL.

- [ ] **Step 3: Implement.** In `boost-plan.jq`:

Parameter block additions:

```jq
| (.forecast // null) as $fc
| (if $fc == null then 0
   elif (($fc | has("pool")) and ($fc | has("projected_cycle_total"))) | not then null
   else ([0, ((($fc.pool - $fc.projected_cycle_total)
               * ([([($fc.utilization // 0.5), 0] | max), 1] | min)) | floor)] | max)
   end) as $forecast_headroom
```

Guard chain: extend Task 2's `if` with a preceding branch:

```jq
| if $forecast_headroom == null then
    {error: "forecast requires pool and projected_cycle_total"}
  elif ($has_days | not) and any(.donors[]; (.run_rate // null) != null) then
```

Funding order (replace the single `$delta`→allocator hand-off):

```jq
| ([$delta, $forecast_headroom] | min) as $forecast_funded
| ($delta - $forecast_funded) as $donor_delta
```

The reduce allocator starts from `{remaining: $donor_delta, takes: []}`. Downstream:

```jq
| ($donor_delta - $alloc.remaining) as $donor_funded
| ($forecast_funded + $donor_funded) as $funded
```

`shortfall` stays `$alloc.remaining`; `recipient_after.cap_after` stays `$r.cap + $funded`.

Output additions:

```jq
    forecast_headroom: $forecast_headroom,
    forecast_funded: $forecast_funded,
    donor_funded: $donor_funded,
    zero_sum: ($forecast_funded == 0),
```

Warning when `forecast_funded > 0`:

```jq
      + (if $forecast_funded > 0
           then ["\($forecast_funded) ACUs funded from enterprise forecast headroom (pool \($fc.pool) − projected \($fc.projected_cycle_total), utilization \($fc.utilization // 0.5)) — Σ explicit caps grows by \($forecast_funded); NOT zero-sum. Exposure is bounded by the linear projection only."]
           else [] end)
```

`sum_before`/`sum_after` computation unchanged (participant caps) — with forecast funding, `sum_after − sum_before == forecast_funded`; assert that relationship in the header comment.

- [ ] **Step 4: Run tests** — full file PASS; `zsh -n` clean.

- [ ] **Step 5: Commit**

```bash
git add claude/devin-acu-governor/lib/boost-plan.jq claude/devin-acu-governor/test/boost-plan.test.zsh
git commit -m "feat(dag): boost funds from enterprise forecast headroom before cutting donors"
```

### Task 4: borrow-caps.jq — forecast-headroom funding

**Files:**
- Modify: `claude/devin-acu-governor/lib/borrow-caps.jq`
- Test: `claude/devin-acu-governor/test/borrow-caps.test.zsh`

**Interfaces:**
- Same `forecast` input object as Task 3, same validation error. New outputs: `donor_available` (donor-only headroom), `forecast_headroom`, `forecast_funded`; `total_available = donor_available + forecast_headroom`; `zero_sum` true only when `forecast_funded == 0` and sums match; `sum_after == sum_before + forecast_funded`.
- Consumes: Task 1's parameter block and donor partition.

- [ ] **Step 1: Write failing tests:**

```zsh
# FB1. Forecast-first seeding: donors untouched when headroom covers borrowed.
#      recipient consumed 100 -> min_cover-style cap 100 via forecast only.
out=$(run_jq '{"require_forecast":false,"min_donor_cap_after":0,"min_donor_headroom":0,
  "forecast":{"pool":24000,"projected_cycle_total":20454},
  "recipients":[{"email":"r1@x","consumed":100}],
  "donors":[{"email":"d1@x","cap":300,"consumed":250}]}')
assert_contains "FB1 headroom" "$out" '"forecast_headroom":1773'
assert_contains "FB1 fc funded > 0" "$out" '"forecast_funded":'
assert_contains "FB1 not zero-sum" "$out" '"zero_sum":false'
assert_contains "FB1 warn" "$out" 'funded from enterprise forecast headroom'

# FB2. Split: forecast 40 + donors fund the rest; donor_takes shrink accordingly.
out=$(run_jq '{"require_forecast":false,"min_donor_cap_after":0,"min_donor_headroom":0,
  "forecast":{"pool":1000,"projected_cycle_total":920},
  "recipients":[{"email":"r1@x","consumed":100}],
  "donors":[{"email":"d1@x","cap":500,"consumed":0}]}')
assert_contains "FB2 headroom 40" "$out" '"forecast_headroom":40'
assert_contains "FB2 fc funded 40" "$out" '"forecast_funded":40'

# FB3. Malformed forecast.
out=$(run_jq '{"forecast":{"pool":1000},"recipients":[{"email":"r1@x","consumed":1}],"donors":[]}')
assert_contains "FB3 error" "$out" '"error":"forecast requires pool and projected_cycle_total"'
```

(FB2 exact expectations: donor avail 500, total_available 540, base_sum 100 → even_share share = min(floor((540−100)/1), 500) = 440 → cap 540, borrowed 540, forecast_funded 40, donor gives 500. Assert `"given":500` and `"cap":540` too.)

- [ ] **Step 2: Run to verify failure** — FB1–FB3 FAIL.

- [ ] **Step 3: Implement.** Mirror Task 3's `$fc`/`$forecast_headroom` parameter code verbatim into `borrow-caps.jq`'s parameter block; add the malformed-forecast `elif` branch (`{error: "forecast requires pool and projected_cycle_total"}`) ahead of the days_left guard. Then:

```jq
    | ([ $cands[].available ] | add // 0)          as $donor_available
    | ($donor_available + $forecast_headroom)      as $total_available
```

After `$borrowed` is known:

```jq
    | ([$borrowed, $forecast_headroom] | min) as $forecast_funded
    | ($borrowed - $forecast_funded) as $donor_borrowed
```

The donor draw reduce starts from `{remaining: $donor_borrowed, takes: []}`; `$sum_donor_after = $sum_donor_before - $donor_borrowed`. Output additions: `donor_available: $donor_available, forecast_headroom: $forecast_headroom, forecast_funded: $forecast_funded`; the forecast warning string from Task 3; `zero_sum: (($forecast_funded == 0) and (.sum_before == .sum_after))` (note: with forecast funding, `sum_after == sum_before + forecast_funded` — state it in the header comment).

- [ ] **Step 4: Run tests** — full file PASS; `zsh -n` clean.

- [ ] **Step 5: Commit**

```bash
git add claude/devin-acu-governor/lib/borrow-caps.jq claude/devin-acu-governor/test/borrow-caps.test.zsh
git commit -m "feat(dag): set-limits-new seeding funds from forecast headroom before donors"
```

### Task 5: compute-caps.jq — forecast warnings for the full re-prorate

**Files:**
- Modify: `claude/devin-acu-governor/lib/compute-caps.jq`
- Test: `claude/devin-acu-governor/test/compute-caps.test.zsh`

**Interfaces:**
- Produces: optional top-level `days_left` + per-user `run_rate`; per-cap `projected` field (`consumed + run_rate*days_left`, rounded up, null when no run_rate) and a warning per user whose `projected > cap`. No cap values change — warnings only.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write failing tests:**

```zsh
# P1. Heavy burner flagged: pool 1000, 2 users. consumed 100+100, share 400.
#     u1 run_rate 30 x days_left 20 -> projected 700 > cap 500: warn.
out=$(run_jq '{"pool":1000,"days_left":20,"users":[
  {"email":"u1@x","consumed":100,"run_rate":30},
  {"email":"u2@x","consumed":100,"run_rate":1}]}')
assert_contains "P1 projected" "$out" '"projected":700'
assert_contains "P1 warn" "$out" 'u1@x projected 700 ACUs by cycle end exceeds proposed cap 500'
# P2. No run_rate -> projected null, no forecast warning.
out=$(run_jq '{"pool":1000,"users":[{"email":"u1@x","consumed":100}]}')
assert_contains "P2 no projected" "$out" '"projected":null'
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement.** In `compute-caps.jq`: bind `(.days_left // 0) as $days_left` in the top pipeline; change `caprow` to:

```jq
def caprow($cap; $days_left):
  {email, consumed}
  + uid
  + {cap: $cap,
     projected: (if (.run_rate // null) == null then null
                 else ((.consumed + .run_rate * $days_left) | ceil) end)};
```

(update all `caprow(X)` call sites to `caprow(X; $days_left)`). After `sum_caps` is added, append forecast warnings:

```jq
    | . + {warnings: (.warnings + [ .caps[]
        | select(.projected != null and .projected > .cap)
        | "\(.email) projected \(.projected) ACUs by cycle end exceeds proposed cap \(.cap) — even share will not hold; plan a boost or exclude from donor pools" ])}
```

- [ ] **Step 4: Run tests** — `zsh claude/devin-acu-governor/test/compute-caps.test.zsh` all PASS (legacy tests get no new keys; `projected:null` is additive — update any exact-object assertions that now mismatch by adding `"projected":null`).

- [ ] **Step 5: Commit**

```bash
git add claude/devin-acu-governor/lib/compute-caps.jq claude/devin-acu-governor/test/compute-caps.test.zsh
git commit -m "feat(dag): set-limits proration warns when a user's forecast exceeds their proposed cap"
```

### Task 6: dashboard.jq — org-gate overcommit detection

**Files:**
- Modify: `claude/devin-acu-governor/lib/dashboard.jq`
- Test: `claude/devin-acu-governor/test/dashboard-orggate.test.zsh` (new; if a dashboard fixture test already exists, extend it instead)

**Interfaces:**
- Produces: per-org fields `sum_explicit_user_caps` (Σ explicit user caps whose `billing_org_id` == org) and `user_cap_overcommit` (that sum − local cap; null when org local cap unset); enterprise warning row when overcommit > 0.
- Consumes: existing `$user_rows[].billing_org_id` / `.explicit_cycle_acu_limit` and `$org_rows`.

- [ ] **Step 1: Write failing test.** Build the minimal slurpfile fixture set in the test's tempdir (empty/degraded docs for sessions, model analytics, donor record; one org `org-1` with `local_agent.cycle_acu_limit 100`; two users attributed to `org-1` with explicit caps 80 and 60; consumption docs zeroed). Invoke exactly as `lib/dashboard.zsh` does:

```zsh
#!/usr/bin/env zsh
set -u
script_dir=${0:A:h}
source "${script_dir}/harness.zsh"
lib="${script_dir}/../lib"
tmp=$(mktemp -d); trap "rm -rf $tmp" EXIT
print -r -- '{"total_acus":0,"consumption_by_date":[]}' > $tmp/ent.json
print -r -- '{"items":[{"org_id":"org-1","name":"Org One","max_session_acu_limit":null,"max_cycle_acu_limit":null}]}' > $tmp/orgs.json
print -r -- '{"org_id":"org-1","daily":{"total_acus":0,"consumption_by_date":[]}}' > $tmp/orgd.json
print -r -- '{"org_id":"org-1","limits":{"local_agent":{"cycle_acu_limit":100}}}' > $tmp/orgl.json
print -r -- '{"items":[{"user_id":"u1","email":"u1@x","name":"U1","role_assignments":[{"org_id":"org-1"}]},{"user_id":"u2","email":"u2@x","name":"U2","role_assignments":[{"org_id":"org-1"}]}]}' > $tmp/users.json
print -r -- '{"user_id":"u1","daily":{"total_acus":0,"consumption_by_date":[]}}' > $tmp/userd.json
print -r -- '{"user_id":"u2","daily":{"total_acus":0,"consumption_by_date":[]}}' >> $tmp/userd.json
print -r -- '{"user_id":"u1","limits":{"local_agent":{"cycle_acu_limit":80,"billing_org_id":"org-1"}}}' > $tmp/userl.json
print -r -- '{"user_id":"u2","limits":{"local_agent":{"cycle_acu_limit":60,"billing_org_id":"org-1"}}}' >> $tmp/userl.json
print -r -- '{}' > $tmp/defaultl.json
print -r -- '{"available":false,"donors":{}}' > $tmp/donorrec.json
print -r -- '{"available":false,"items":[]}' > $tmp/sessions.json
print -r -- '{"available":false,"rows":[]}' > $tmp/modela.json
out=$(jq -c -n --argjson now 1756800000 --argjson pool 24000 \
  --argjson after 1755302400 --argjson before 1757894400 \
  --arg generated_at test --arg refresh_minutes "" \
  --slurpfile ent $tmp/ent.json --slurpfile orgs $tmp/orgs.json \
  --slurpfile orgd $tmp/orgd.json --slurpfile orgl $tmp/orgl.json \
  --slurpfile users $tmp/users.json --slurpfile userd $tmp/userd.json \
  --slurpfile userl $tmp/userl.json --slurpfile defaultl $tmp/defaultl.json \
  --slurpfile donorrec $tmp/donorrec.json --slurpfile sessions $tmp/sessions.json \
  --slurpfile modela $tmp/modela.json -f $lib/dashboard.jq)
assert_contains "org sum caps" "$out" '"sum_explicit_user_caps":140'
assert_contains "org overcommit" "$out" '"user_cap_overcommit":40'
assert_contains "org gate warn" "$out" 'blocked by the org gate'
print_summary
```

(Match the real `--arg`/`--argjson` list against `lib/dashboard.zsh` before finalizing — copy its invocation verbatim; add/remove args to fit.)

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement.** In `dashboard.jq`, after `$user_rows` is bound, derive per-org explicit-cap sums and rebind org rows:

```jq
| ($user_rows
   | map(select(.explicit_cycle_acu_limit != null and .billing_org_id != null))
   | group_by(.billing_org_id)
   | map({key: .[0].billing_org_id, value: ([.[].explicit_cycle_acu_limit] | add)})
   | from_entries) as $org_explicit_caps
| ($org_rows | map(. + {
    sum_explicit_user_caps: ($org_explicit_caps[.org_id] // 0),
    user_cap_overcommit: (if .local.limit == null then null
      else (($org_explicit_caps[.org_id] // 0) - .local.limit) end)
  })) as $org_rows
```

Use the rebound `$org_rows` in `orgs:` output (jq rebinding shadows — place this before the final output object). Append to `warnings`:

```jq
      + [$org_rows[]
         | select(.user_cap_overcommit != null and .user_cap_overcommit > 0)
         | "\(.name) org Local Agent cap \(.local.limit) < Σ member explicit user caps \(.sum_explicit_user_caps) (overcommit \(.user_cap_overcommit)) — users with personal headroom can be blocked by the org gate; raise the org cap (dag set limit global) or clear it"]
```

- [ ] **Step 4: Run tests** — new test PASS; run `zsh claude/devin-acu-governor/test/dag-cli.test.zsh` too (dashboard consumers) — PASS.

- [ ] **Step 5: Commit**

```bash
git add claude/devin-acu-governor/lib/dashboard.jq claude/devin-acu-governor/test/dashboard-orggate.test.zsh
git commit -m "feat(dag): dashboard flags org-gate overcommit (org cap < sum of member user caps)"
```

### Task 7: playbooks + README

**Files:**
- Modify: `claude/devin-acu-governor/playbooks/_common.md`, `boost.md`, `boost-all.md`, `set-limits-new.md`, `set-limits.md`
- Modify: `claude/devin-acu-governor/README.md`

**Interfaces:**
- Consumes: every field/flag introduced in Tasks 1–6, exact names as defined there.

- [ ] **Step 1: `_common.md` hard-rule edits.**
  - Rule 11: append one sentence: "Donor-side backstops are equally canonical: `min_donor_cap_after` 50 and `min_donor_headroom` 25 are jq built-in defaults — no donor plan may leave a donor within 25 ACUs of their projected consumption or below cap 50."
  - Rule 12: append: "Every donor plan must carry `run_rate` and `days_left`; the planners hard-error on `run_rate` without `days_left` and exclude no-`run_rate` donors by default (`require_forecast`). Passing `require_forecast: false` requires stating in the preview why recent-usage data is unavailable."
  - New rule 14 — **Forecast-headroom funding**: "When the enterprise linear projection (`rate = cycle consumed / elapsed_days`, `projected = rate × cycle_days`, same math as the dashboard) is UNDER `DAG_MONTHLY_ACU_POOL`, boost/seed plans may fund growth from `forecast_headroom = floor((pool − projected) × utilization)`, utilization 0.5 default, up to 1.0 only on explicit in-session request. The preview must show `forecast_headroom`, `forecast_funded`, and the Σ-caps growth, and say the plan is NOT zero-sum. Forecast funding never bypasses hard rules 2 or 11. Compute the projection from live daily data in the same run — never from a stale dashboard file."
  - New rule 15 — **Org-gate consistency**: "After any confirmed user-cap write, GET the org ACU limits of every affected user's billing org. If Σ explicit member user caps > org `local_agent.cycle_acu_limit`, report the overcommit and offer an org-cap PATCH preview to `Σ member caps` (or clearing the org cap) — a separate write requiring its own `CONFIRM DAG WRITE`. Never leave a run silent about an org gate that can block users the run just funded."

- [ ] **Step 2: `boost.md`.** Step 5 input block gains `"min_donor_headroom": 25, "require_forecast": true,` and, when the enterprise projection is UNDER pool, `"forecast": {"pool": <DAG_MONTHLY_ACU_POOL>, "projected_cycle_total": <live linear projection>, "utilization": 0.5}`. Add step 5a: "Enterprise forecast. GET `/v3/enterprise/consumption/daily` for the cycle window; compute `projected_cycle_total = total_acus / elapsed_days × cycle_days`; include the `forecast` block only when projection < pool (rule 14)." Step 6 preview additions: `forecast_headroom`, `forecast_funded`, `donor_funded`, Σ-caps delta, NOT-zero-sum callout. Note in step 4 that no-`run_rate` donors are excluded by the planner, not by hand.

- [ ] **Step 3: `boost-all.md`.** Same three edits (input block in step 7, forecast fetch folded into step 1's consumption call, batch preview shows total `forecast_funded` across recipients and Σ-caps growth). Shared forecast headroom is a single budget: pass the *remaining* forecast headroom to each sequential recipient plan, decremented by earlier recipients' `forecast_funded`, exactly like donor caps are carried forward.

- [ ] **Step 4: `set-limits-new.md`.** Step 7 input gains `"min_donor_cap_after": 50, "min_donor_headroom": 25, "require_forecast": true` and the same conditional `forecast` block; document `donor_available`/`forecast_headroom`/`forecast_funded` outputs and that `zero_sum` is false under forecast funding (preview must show Σ growth instead of proving equality). Update step 9's zero-sum proof line to: "prove `sum_after − sum_before == forecast_funded` (0 when no forecast funding)."

- [ ] **Step 5: `set-limits.md`.** Step 6 input gains `"days_left": <days left>` and per-user `"run_rate"` (from the same consumption data, last-7-day average); document the new `projected` field and forecast warnings and require the preview to list every warned user under "will not survive the cycle at even share — boost candidates". Step 12 (full-team mode) addition: "Rewrite the donor record empty with the current cycle epochs — a full re-prorate re-bases every cap, making all recorded donors whole." Append org-gate check step (rule 15) after live verify. Same org-gate step appended to `boost.md`, `boost-all.md`, `set-limits-new.md`.

- [ ] **Step 6: README.** Update the devin-acu-governor README's planner/flow descriptions: donor floor formula, forecast requirement, forecast-headroom funding (D1–D3, D6), dashboard org-gate warning, donor-record wipe on full set-limits.

- [ ] **Step 7: Verify + commit.** `zsh -n` on any touched zsh (none expected); re-run all six test files:

```bash
for t in claude/devin-acu-governor/test/*.test.zsh; do zsh "$t" || break; done
git add claude/devin-acu-governor/playbooks claude/devin-acu-governor/README.md
git commit -m "docs(dag): forecast-safe borrow, forecast-headroom funding, org-gate consistency playbook rules"
git push
```

---

## Phase B — operational reset (after Phase A merges; live API, no repo changes)

Run `dag set-limits` (full-team re-prorate — D5). The session will:

1. Read cycle, roster, per-user consumption + last-7-day run rates, activity filter.
2. Scope-confirm the eligible engineer list (standing scope answer applies: @cognition.ai = 0, no Windsurf analytics row = 5, rest = jq cap).
3. Run the new `compute-caps.jq` with `days_left` + `run_rate` — preview shows every user whose forecast outruns the even share.
4. Preview all caps; **`CONFIRM DAG WRITE`**; PATCH; live-verify.
5. Rewrite ledger; **wipe donor record** (all donors made whole).
6. Org-gate check (rule 15): report any org whose cap < Σ new user caps; offer org-cap PATCH or clear under a second `CONFIRM DAG WRITE`.

Result: every active engineer re-based for the ~30 remaining cycle days; the 150→50 donor is restored by the re-prorate.

## Parked (explicitly out of scope)

- Daily "how over am I" watchdog utility (goal item 3) — revisit via /wayfinder after Phase B.
- Invenco inv.dag re-pin.
