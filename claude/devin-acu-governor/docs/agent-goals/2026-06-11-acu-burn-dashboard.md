# Goal: Add ACU Burn-Rate + Forecast Dashboard to `dag`

Repo: `/Users/amittiwari/Projects/Tools-Utilities/daemons/claude/devin-acu-governor`

## Objective

Extend `dag` with a read-only dashboard command that:

1. Fetches Devin Enterprise ACU cycle, daily consumption, and org limits.
2. Computes burn-rate, remaining ACUs, projected cycle-end spend, and org cap risk.
3. Writes a local dashboard data artifact.
4. Injects that data into a local HTML dashboard app.
5. Opens it locally so Amit can view it in browser.

Command target:

```zsh
dag dashboard
dag dashboard --no-open
dag dashboard --out /tmp/dag-dashboard
```

## Constraints

- Use zsh. New scripts: `#!/usr/bin/env zsh`, `.zsh`, parse-check with `zsh -n`.
- Do not use shellcheck for zsh.
- Do not leak `DEVIN_COG_KEY`.
- Dashboard is read-only. No API writes.
- Prefer zero npm/build dependency. Generate static HTML/CSS/JS.
- Data injection should avoid browser CORS/file fetch issues:
  - write `dashboard-data.js`
  - content shape: `window.DAG_DASHBOARD_DATA = {...};`
  - `dashboard.html` loads this file.
- Local open:
  - macOS: `open "$dashboard_html"`
  - `--no-open`: just print path.
- Existing tests must pass: `zsh test/run.zsh`.

## Files likely touched

- Modify: `bin/dag`
  - Add `dashboard` command to usage and command dispatch.
  - Route to local implementation, not Claude playbook.
- Create: `lib/dashboard.zsh`
  - Fetch APIs, compute forecast, write data/app files, open browser.
- Create: `web/dashboard/dashboard.html`
  - Static dashboard template.
- Create: `web/dashboard/dashboard.css`
- Create: `web/dashboard/dashboard.js`
- Create: `test/dashboard.test.zsh`
- Modify: `test/run.zsh`
- Modify: `README.md`

## API endpoints

Use existing key resolution from `lib/key-resolve.zsh`.

Required calls:

```text
GET /v3/enterprise/consumption/cycles
GET /v3/enterprise/consumption/daily?time_after=<cycle_after>&time_before=<cycle_before>
GET /v3/enterprise/organizations
GET /v3/enterprise/consumption/daily/organizations/{org_id}?time_after=<cycle_after>&time_before=<cycle_before>
```

Base:

```text
https://api.devin.ai
Authorization: Bearer $DEVIN_COG_KEY
```

## Forecast math

Current cycle = cycle where:

```text
after <= now < before
```

Compute:

```text
cycle_days = ceil((before - after) / 86400)
elapsed_days = max(1, ceil((min(now, before) - after) / 86400))
left_days = max(0, cycle_days - elapsed_days)

enterprise_consumed = daily.total_acus
remaining = DAG_MONTHLY_ACU_POOL - enterprise_consumed
daily_run_rate = enterprise_consumed / elapsed_days
projected_cycle_total = daily_run_rate * cycle_days
projected_over_under = DAG_MONTHLY_ACU_POOL - projected_cycle_total
```

Org row:

```text
org_consumed = org_daily.total_acus
org_run_rate = org_consumed / elapsed_days
org_projected = org_run_rate * cycle_days

if max_cycle_acu_limit is null:
  status = "uncapped"
else if org_consumed >= max_cycle_acu_limit:
  status = "over"
else if org_projected > max_cycle_acu_limit:
  status = "forecast_over"
else if org_consumed / max_cycle_acu_limit >= 0.95:
  status = "critical"
else if org_consumed / max_cycle_acu_limit >= 0.85:
  status = "warning"
else:
  status = "ok"
```

Product split:

```text
sum consumption_by_date[].acus_by_product.{devin,cascade,terminal,review}
```

Use `jq` for JSON generation/math where practical. No mental arithmetic in output.

## JSON data contract

Write:

```text
$OUT_DIR/dashboard-data.js
$OUT_DIR/data.json
$OUT_DIR/dashboard.html
$OUT_DIR/dashboard.css
$OUT_DIR/dashboard.js
```

`dashboard-data.js`:

```js
window.DAG_DASHBOARD_DATA = {
  "generated_at": "2026-06-10T...",
  "cycle": {
    "after": 1778918400,
    "before": 1781596800,
    "start_date": "2026-05-16",
    "end_date": "2026-06-16",
    "cycle_days": 31,
    "elapsed_days": 25,
    "left_days": 6
  },
  "pool": 24000,
  "enterprise": {
    "consumed": 12345.67,
    "remaining": 11654.33,
    "daily_run_rate": 493.83,
    "projected_cycle_total": 15308.73,
    "projected_over_under": 8691.27,
    "verdict": "UNDER"
  },
  "product_split": [
    {"product":"devin","acus":1000},
    {"product":"cascade","acus":9000},
    {"product":"terminal","acus":2000},
    {"product":"review","acus":345.67}
  ],
  "daily": [
    {"date":"2026-05-16","epoch":1778918400,"acus":100,"devin":20,"cascade":70,"terminal":10,"review":0}
  ],
  "orgs": [
    {
      "org_id": "...",
      "name": "Platform",
      "consumed": 1234,
      "daily_run_rate": 49.36,
      "projected": 1530,
      "max_cycle_acu_limit": 2000,
      "max_session_acu_limit": 100,
      "pct_limit": 0.617,
      "status": "ok"
    }
  ],
  "warnings": []
};
```

## Dashboard UI requirements

`dashboard.html` should show:

1. Header
   - “Devin ACU Burn Dashboard”
   - Generated time
   - Cycle date range
2. Headline cards
   - Consumed ACUs
   - Remaining ACUs
   - Daily run rate
   - Projected cycle-end
   - Verdict: UNDER / OVER
3. Daily burn chart
   - Simple SVG or CSS bar/line chart. No dependency required.
4. Product split
   - bars for devin/cascade/terminal/review
5. Org table
   - name
   - consumed
   - projected
   - max cycle cap
   - max session cap
   - pct of cap
   - status badge
6. Warnings panel
   - orgs forecast over cap
   - orgs already over cap
   - uncapped orgs

Keep it readable. No perfection rabbit hole.

## CLI behavior

```zsh
dag dashboard
```

Default output:

```text
$DAG_STATE_DIR/dashboard/latest/
```

Flags:

```text
--no-open       do not open browser
--out <dir>     write dashboard files to dir
--json-only     only write dashboard-data.js and data.json, no app/open
```

Print final paths:

```text
Dashboard written:
  /.../dashboard.html
  /.../dashboard-data.js
Open:
  file:///.../dashboard.html
```

## Tests

Create fixtures in `test/fixtures/dashboard/`:

- `cycles.json`
- `enterprise-daily.json`
- `organizations.json`
- `org-platform-daily.json`
- `org-sandbox-daily.json`

Test cases:

1. `dag dashboard --no-open --out "$tmpdir"` exits 0.
2. Writes `dashboard.html`, `dashboard-data.js`, `dashboard.css`, `dashboard.js`.
3. `dashboard-data.js` contains `window.DAG_DASHBOARD_DATA =`.
4. No key string appears in generated files or stdout.
5. Forecast math deterministic with `DAG_NOW_EPOCH`.
6. Org status classification covers:
   - ok
   - warning
   - critical
   - forecast_over
   - over
   - uncapped
7. Missing required API read exits non-zero and quotes exact response body.
8. `dag help` includes dashboard command.
9. `DAG_PRINT_PROMPT=1 dag dashboard` should not launch Claude; either reject with useful message or run local dashboard path. Prefer local run.

Mock `curl` in tests via temp `PATH`, same style as existing tests.

## Implementation order

1. Read existing:
   - `bin/dag`
   - `lib/key-resolve.zsh`
   - `lib/doctor.zsh`
   - `test/dag-cli.test.zsh`
   - `test/harness.zsh`
   - `README.md`
2. Add failing tests first.
3. Add `dashboard` usage/dispatch.
4. Implement `lib/dashboard.zsh`.
5. Add static dashboard template assets.
6. Add docs to README.
7. Run:
   ```zsh
   zsh -n bin/dag lib/*.zsh test/*.zsh
   zsh test/run.zsh
   ```
8. Manual smoke:
   ```zsh
   dag dashboard --no-open --out /tmp/dag-dashboard
   ls -la /tmp/dag-dashboard
   open /tmp/dag-dashboard/dashboard.html
   ```

## Acceptance criteria

Done only when:

- `dag dashboard --no-open` generates local dashboard files.
- Dashboard opens from file path without local server.
- Forecast and org cap status are visible.
- Existing dag commands still work.
- All tests pass.
- README documents command, flags, API endpoints, and limitations.
- No API writes introduced.
- No secrets printed or written.
