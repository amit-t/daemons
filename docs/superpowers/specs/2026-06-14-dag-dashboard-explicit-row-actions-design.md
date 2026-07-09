# DAG Dashboard Explicit Row Actions Design

## Context

The `dag dashboard` React app currently opens the per-user detail drawer from two broad gestures in the user cap table:

- clicking any user row through `SortableTable`'s `onRowClick` support;
- hovering or clicking the email cell, because `EmailCell.trigger()` copies the email and calls `onSelect(user)`.

That behavior came from commit `9889dfb` and makes accidental hover over an email open the detail drawer.

## Goal

Make copy and detail navigation explicit in the user cap table:

- hovering an email address does not copy anything and does not open detail;
- clicking the email text itself does not open detail;
- a dedicated button beside the email copies the email address to the clipboard;
- a dedicated row action button opens the per-user detail drawer;
- ordinary row clicks no longer open the detail drawer.

## Design

`UserTable.tsx` owns the table-specific controls. Replace the current hover/click email button with an email cell that renders static email text plus an adjacent copy button. Reuse `copyToClipboard(email)` so the table uses the same clipboard implementation as the detail drawer, but do not call `onSelect` from any copy path.

Add a final non-sortable `Details` column. Its button calls `onSelect(user)` and stops event propagation, making it the only control in the row that opens detail. Remove `onRowClick={onSelect}` from the `SortableTable` call so the row is visually and functionally not a broad click target.

Style the new controls as small inline action buttons matching the existing amber terminal theme. Keep `SortableTable` generic and unchanged unless tests reveal it needs accessibility support; this change is localized to the user cap table and dashboard documentation.

## Testing

Add Vitest + React Testing Library for the dashboard app. Test `UserTable` directly with a realistic `UserRow` fixture:

1. hovering the email text does not call `onSelect` and does not call clipboard;
2. clicking the email text does not call `onSelect` and does not call clipboard;
3. clicking the copy button writes the email and does not call `onSelect`;
4. clicking the row outside controls does not call `onSelect`;
5. clicking the details button calls `onSelect` with that user.

## Documentation

Update:

- `claude/devin-acu-governor/README.md` dashboard feature list;
- `claude/devin-acu-governor/web/dashboard-app/README.md` component descriptions and dev loop;
- run a production build to verify the generated `web/dashboard-app/dist/` assets; `dist/` remains gitignored and is not committed.

## Verification

Run from `claude/devin-acu-governor/web/dashboard-app` (test dependencies also upgrade Vite/plugin tooling as needed so `npm audit --audit-level high` is clean):

```zsh
npm test -- --run
npm run build
npm audit --audit-level high
```

Run from `claude/devin-acu-governor`:

```zsh
zsh test/run.zsh
```

Then audit source text for removed hover/copy-open wording and run `git status --short` before committing only scoped tracked files.
