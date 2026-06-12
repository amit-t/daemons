# dag dashboard app

React (Vite + TypeScript + recharts) frontend for `dag dashboard`. Local-only: served by `lib/dashboard.zsh` on `127.0.0.1`, never deployed.

## How it runs

`dag dashboard` builds this app once (`npm install && npm run build` → `dist/`, both gitignored), copies `dist/` next to the generated `data.json` in the output dir, and serves that dir with `python3 -m http.server` on `127.0.0.1`. The app fetches `./data.json` on load and re-polls it with `cache: no-store` on the backend refresh cadence embedded in `data.json` (falling back to 60 s for static snapshots). The header shows `refreshing` while manual/auto background fetches are in flight and `refreshed` after success; when the `dag dashboard --refresh` backend loop rewrites the file, the UI updates in place — no page reload.

Force a rebuild after changing app source: `dag dashboard --rebuild`.

## Dev loop

```zsh
npm install
npm run dev        # vite dev server; put a data.json in public/ or the served dir
npm run build      # tsc -b && vite build → dist/
```

## Structure

| Path | Responsibility |
|---|---|
| `src/types.ts` | Shape of `data.json` (mirrors `lib/dashboard.jq` output) |
| `src/useDashboardData.ts` | Manual + auto background polling hook; uses backend refresh cadence and keeps last good snapshot on fetch failure |
| `src/App.tsx` | Layout: header with refresh button/status, cycle progress, KPI cards including capped user total, panels |
| `src/components/BurnChart.tsx` | Daily stacked product bars + cumulative/forecast view with pool reference line |
| `src/components/ProductSplit.tsx` | Product donut + share table |
| `src/components/OrgTable.tsx` | Org table: status filter chips, sortable columns, cap meters |
| `src/components/UserTable.tsx` | User cap table: text search, status + cap-source filters, sortable columns, billing org last; rows click through to the detail drawer |
| `src/components/UserDetail.tsx` | Per-user drawer: daily ACU line chart over the cycle (cap-pace reference line), Devin Cloud session stats, model + surface (IDE) bar lists from Windsurf analytics, product split; closes on Esc/✕/backdrop |
| `src/components/SortableTable.tsx` | Generic sortable table (nulls always sink to bottom; optional `onRowClick`) |
| `src/app.css` | Phosphor ops theme (dark graphite, amber accent, IBM Plex Mono / Chakra Petch) |

Fonts are bundled via `@fontsource` so the app works fully offline.
