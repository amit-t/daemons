# dag dashboard app

React (Vite + TypeScript + recharts) frontend for `dag dashboard`. Local-only: served by `lib/dashboard.zsh` on `127.0.0.1`, never deployed.

## How it runs

`dag dashboard` builds this app once (`npm install && npm run build` → `dist/`, both gitignored), copies `dist/` next to the generated `data.json` in the output dir, and serves that dir with `python3 -m http.server` on `127.0.0.1`. The app fetches `./data.json` on load and polls `./status.json` — the lightweight live refresh channel the backend rewrites far more often than the heavy snapshot — every second with `cache: no-store`. `status.json` drives a `next refresh in 4m 32s` countdown (from `next_refresh_epoch`) and, while the `dag dashboard --refresh` backend loop is fetching, a `Refreshing N%` progress bar (with the current phase) that replaces the `Refresh now` button. When `status.json` advertises a new `generated_at`, the app pulls the fresh `data.json` and updates in place — no page reload. With no backend loop (static snapshot) `status.json` is absent/`static` and the header shows `data refreshed X ago` plus a `Refresh now` button.

Force a rebuild after changing app source: `dag dashboard --rebuild`.

## Dev loop

```zsh
npm install
npm run dev        # vite dev server; put a data.json in public/ or the served dir
npm run build      # tsc -b && vite build → dist/
npm test -- --run  # Vitest + React Testing Library interaction tests
```

## Structure

| Path | Responsibility |
|---|---|
| `src/types.ts` | Shape of `data.json` + `status.json` (mirror `lib/dashboard.jq` / `lib/dashboard.zsh` output) |
| `src/useDashboardData.ts` | Polls `status.json` (1 s) for refresh state, pulls `data.json` on a new `generated_at`, exposes manual `refreshNow`, keeps last good snapshot on fetch failure |
| `src/components/RefreshControls.tsx` | Console-meta row: live countdown, `Refreshing N%` progress bar, `Refresh now` button; isolates the per-second tick from the charts |
| `src/App.tsx` | Layout: header with `RefreshControls`, cycle progress, KPI cards including capped user total, panels |
| `src/components/BurnChart.tsx` | Daily stacked product bars + cumulative/forecast view with pool reference line |
| `src/components/ProductSplit.tsx` | Product donut + share table |
| `src/components/OrgTable.tsx` | Org table: status filter chips, sortable columns, cap meters |
| `src/components/UserTable.tsx` | User cap table: text search, status + cap-source filters, sortable columns, billing org, explicit Copy button beside each email, and a Details action button that opens the detail drawer without row-hover/click side effects |
| `src/components/UserDetail.tsx` | Per-user drawer: daily ACU line chart over the cycle (cap-pace reference line), Devin Cloud session stats, model + surface (IDE) bar lists from Windsurf analytics, product split; the header email is a click-to-copy token; closes on Esc/✕/backdrop |
| `src/components/CopyEmail.tsx` | Click-to-copy email token with a transient `copied` / `copy failed` tag (used in the detail drawer; the table has its own compact Copy action) |
| `src/components/SortableTable.tsx` | Generic sortable table (nulls always sink to bottom; optional `onRowClick`) |
| `src/clipboard.ts` | `copyToClipboard(text)` — async Clipboard API with a hidden-textarea `execCommand` fallback |
| `src/app.css` | Phosphor ops theme (dark graphite, amber accent, IBM Plex Mono / Chakra Petch) |

Fonts are bundled via `@fontsource` so the app works fully offline.
