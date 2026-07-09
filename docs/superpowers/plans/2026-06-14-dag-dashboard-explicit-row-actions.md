# DAG Dashboard Explicit Row Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the DAG dashboard user cap table so copy email and open detail are separate explicit buttons.

**Architecture:** Keep the change localized to `UserTable.tsx`: static email text plus an adjacent copy button, and a final explicit details action column. Use Vitest + React Testing Library to verify event boundaries so hover/copy/row click cannot open detail.

**Tech Stack:** React 19, TypeScript, Vite, Vitest, React Testing Library, zsh verification scripts.

---

## File Structure

- Modify `claude/devin-acu-governor/web/dashboard-app/package.json`: add `test` script and UI test dev dependencies; upgrade Vite/plugin dev tooling as needed for a clean high-severity audit.
- Modify `claude/devin-acu-governor/web/dashboard-app/package-lock.json`: dependency lock updates from `npm install`.
- Modify `claude/devin-acu-governor/web/dashboard-app/vite.config.ts`: add Vitest `environment: 'jsdom'` config.
- Create `claude/devin-acu-governor/web/dashboard-app/src/components/UserTable.test.tsx`: regression tests for explicit controls.
- Modify `claude/devin-acu-governor/web/dashboard-app/src/components/UserTable.tsx`: implement static email, copy button, details button, no row click handler.
- Modify `claude/devin-acu-governor/web/dashboard-app/src/app.css`: add inline action styling.
- Modify `claude/devin-acu-governor/web/dashboard-app/README.md`: update dev loop and UserTable description.
- Modify `claude/devin-acu-governor/README.md`: update dashboard behavior wording.
- Verify `claude/devin-acu-governor/web/dashboard-app/dist/**` with a production build; `dist/` is gitignored and not committed.

### Task 1: Baseline and test harness

**Files:**
- Modify: `claude/devin-acu-governor/web/dashboard-app/package.json`
- Modify: `claude/devin-acu-governor/web/dashboard-app/package-lock.json`
- Modify: `claude/devin-acu-governor/web/dashboard-app/vite.config.ts`

- [ ] **Step 1: Run current app build baseline**

```zsh
cd claude/devin-acu-governor/web/dashboard-app
npm run build
```

Expected: exit 0 with TypeScript and Vite build output.

- [ ] **Step 2: Install test dependencies**

```zsh
cd claude/devin-acu-governor/web/dashboard-app
npm install --save-dev vitest jsdom @testing-library/react @testing-library/user-event @testing-library/jest-dom
```

Expected: `package.json` and `package-lock.json` update. If npm reports high-severity Vite/esbuild audit findings, run `npm audit fix --force` and re-run the app tests/build afterward.

- [ ] **Step 3: Add test script**

In `package.json`, change scripts to:

```json
"scripts": {
  "dev": "vite",
  "build": "tsc -b && vite build",
  "preview": "vite preview",
  "test": "vitest"
}
```

- [ ] **Step 4: Configure jsdom**

In `vite.config.ts`, import `defineConfig` from `vitest/config` so TypeScript accepts the `test` key, then add Vitest test config:

```ts
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: 'dist',
    chunkSizeWarningLimit: 900,
  },
  test: {
    environment: 'jsdom',
  },
})
```

### Task 2: Failing interaction tests

**Files:**
- Create: `claude/devin-acu-governor/web/dashboard-app/src/components/UserTable.test.tsx`

- [ ] **Step 1: Write failing tests**

Create `UserTable.test.tsx` with these tests:

```tsx
import { describe, expect, test, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { UserTable } from './UserTable'
import type { UserRow } from '../types'

const alice: UserRow = {
  user_id: 'email|alice',
  email: 'alice@example.com',
  name: 'Alice Example',
  consumed: 42,
  explicit_cycle_acu_limit: 100,
  default_cycle_acu_limit: 200,
  effective_cycle_acu_limit: 100,
  cap_source: 'explicit',
  billing_org_id: 'platform',
  headroom: 58,
  pct_limit: 0.42,
  status: 'ok',
  daily: [],
  product_totals: { devin: 40, cascade: 1, terminal: 1, review: 0 },
  sessions: { count: 2, acus: 12 },
  models: [],
  ides: [],
}

function setup() {
  const onSelect = vi.fn()
  const writeText = vi.fn().mockResolvedValue(undefined)
  Object.assign(navigator, { clipboard: { writeText } })
  render(<UserTable users={[alice]} onSelect={onSelect} />)
  return { onSelect, writeText, user: userEvent.setup() }
}

describe('UserTable explicit email/detail actions', () => {
  beforeEach(() => {
    vi.useRealTimers()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  test('hovering the email text does not copy or open detail', async () => {
    const { onSelect, writeText, user } = setup()

    await user.hover(screen.getByText('alice@example.com'))

    expect(writeText).not.toHaveBeenCalled()
    expect(onSelect).not.toHaveBeenCalled()
  })

  test('clicking the email text does not copy or open detail', async () => {
    const { onSelect, writeText, user } = setup()

    await user.click(screen.getByText('alice@example.com'))

    expect(writeText).not.toHaveBeenCalled()
    expect(onSelect).not.toHaveBeenCalled()
  })

  test('copy email button copies without opening detail', async () => {
    const { onSelect, writeText, user } = setup()

    await user.click(screen.getByRole('button', { name: 'Copy alice@example.com' }))

    expect(writeText).toHaveBeenCalledWith('alice@example.com')
    expect(onSelect).not.toHaveBeenCalled()
  })

  test('clicking row background does not open detail', async () => {
    const { onSelect, user } = setup()

    await user.click(screen.getByText('Alice Example'))

    expect(onSelect).not.toHaveBeenCalled()
  })

  test('details button opens detail for that user', async () => {
    const { onSelect, user } = setup()

    await user.click(screen.getByRole('button', { name: 'Open details for alice@example.com' }))

    expect(onSelect).toHaveBeenCalledTimes(1)
    expect(onSelect).toHaveBeenCalledWith(alice)
  })
})
```

- [ ] **Step 2: Run test to verify RED**

```zsh
cd claude/devin-acu-governor/web/dashboard-app
npm test -- --run src/components/UserTable.test.tsx
```

Expected: tests fail because copy/details buttons are missing and current email hover/click calls clipboard/select.

### Task 3: Implement explicit controls

**Files:**
- Modify: `claude/devin-acu-governor/web/dashboard-app/src/components/UserTable.tsx`
- Modify: `claude/devin-acu-governor/web/dashboard-app/src/app.css`

- [ ] **Step 1: Replace hover-copy email cell with static email plus copy button**

In `UserTable.tsx`, replace the current `EmailCell` with:

```tsx
function EmailCell({ user }: { user: UserRow }) {
  if (!user.email) return <>—</>

  return (
    <span className="email-cell">
      <span className="email-text">{user.email}</span>
      <button
        type="button"
        className="inline-action copy-email-button"
        aria-label={`Copy ${user.email}`}
        title="copy email to clipboard"
        onClick={(e) => {
          e.stopPropagation()
          void copyToClipboard(user.email)
        }}
      >
        Copy
      </button>
    </span>
  )
}
```

- [ ] **Step 2: Add details action button**

Add this component in `UserTable.tsx`:

```tsx
function DetailsButton({ user, onSelect }: { user: UserRow; onSelect: (u: UserRow) => void }) {
  return (
    <button
      type="button"
      className="inline-action details-button"
      aria-label={`Open details for ${user.email || user.name || user.user_id}`}
      title="open user detail"
      onClick={(e) => {
        e.stopPropagation()
        onSelect(user)
      }}
    >
      Details
    </button>
  )
}
```

- [ ] **Step 3: Update columns and remove row click**

In `makeColumns`, render the email cell without `onSelect`, then append a details column:

```tsx
{
  key: 'email',
  label: 'Email',
  sortValue: (u) => u.email.toLowerCase(),
  render: (u) => <EmailCell user={u} />,
},
...
{
  key: 'details',
  label: 'Details',
  render: (u) => <DetailsButton user={u} onSelect={onSelect} />,
},
```

In the `SortableTable` call, remove `onRowClick={onSelect}` entirely.

Change the row-count text to:

```tsx
{rows.length} of {users.length} users · consumed {fmt(rows.reduce((s, u) => s + u.consumed, 0))} ACUs in view · use Copy beside an email to copy it · use Details to open the per-user drawer
```

- [ ] **Step 4: Style the explicit action controls**

In `app.css`, replace `.email-link` styles with:

```css
.email-cell {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}

.email-text { color: var(--text); }

.inline-action {
  font: inherit;
  font-size: 10px;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--amber);
  background: rgba(255, 178, 36, 0.08);
  border: 1px solid rgba(255, 178, 36, 0.28);
  border-radius: 4px;
  padding: 2px 7px;
  cursor: pointer;
}

.inline-action:hover {
  color: var(--bg);
  background: var(--amber);
  border-color: var(--amber);
}

.details-button { min-width: 60px; }
```

- [ ] **Step 5: Run tests to verify GREEN**

```zsh
cd claude/devin-acu-governor/web/dashboard-app
npm test -- --run src/components/UserTable.test.tsx
```

Expected: all UserTable tests pass.

### Task 4: Documentation and build artifacts

**Files:**
- Modify: `claude/devin-acu-governor/web/dashboard-app/README.md`
- Modify: `claude/devin-acu-governor/README.md`
- Verify: `claude/devin-acu-governor/web/dashboard-app/dist/**`

- [ ] **Step 1: Update dashboard app README**

Change the UserTable row to say:

```markdown
| `src/components/UserTable.tsx` | User cap table: text search, status + cap-source filters, sortable columns, billing org last; email cells render a static address with an explicit Copy button; the Details action button opens the detail drawer without row-hover/click side effects |
```

Change the CopyEmail row to say:

```markdown
| `src/components/CopyEmail.tsx` | Click-to-copy email token with a transient `copied` / `copy failed` tag (used in the detail drawer; the table has its own compact Copy action) |
```

Add `npm test -- --run` to the dev loop.

- [ ] **Step 2: Update daemon README**

In the `dag dashboard` feature list, change the user table bullet to mention explicit Copy and Details buttons. Change the per-user detail view bullet to say the Details button opens the drawer, not clicking any row.

- [ ] **Step 3: Rebuild app**

```zsh
cd claude/devin-acu-governor/web/dashboard-app
npm run build
```

Expected: `dist/` updates with a new hashed JS/CSS asset if source changed.

### Task 5: Full verification, commit, push

**Files:**
- All changed scoped files.

- [ ] **Step 1: Run app tests**

```zsh
cd claude/devin-acu-governor/web/dashboard-app
npm test -- --run
```

Expected: all app tests pass.

- [ ] **Step 2: Run app build**

```zsh
cd claude/devin-acu-governor/web/dashboard-app
npm run build
```

Expected: TypeScript and Vite build pass.

- [ ] **Step 3: Run high-severity npm audit**

```zsh
cd claude/devin-acu-governor/web/dashboard-app
npm audit --audit-level high
```

Expected: `found 0 vulnerabilities`.

- [ ] **Step 4: Run daemon test suite**

```zsh
cd claude/devin-acu-governor
zsh test/run.zsh
```

Expected: all zsh/jq daemon tests pass.

- [ ] **Step 5: Audit no stale copy-open wording remains**

```zsh
rg -n "hover/click an email|copy it \+ open detail|hover or click: copy|rows click through|click any user row" claude/devin-acu-governor/README.md claude/devin-acu-governor/web/dashboard-app/README.md claude/devin-acu-governor/web/dashboard-app/src
```

Expected: no matches.

- [ ] **Step 6: Commit and push**

```zsh
git status --short
git add docs/superpowers/specs/2026-06-14-dag-dashboard-explicit-row-actions-design.md docs/superpowers/plans/2026-06-14-dag-dashboard-explicit-row-actions.md claude/devin-acu-governor/README.md claude/devin-acu-governor/web/dashboard-app/package.json claude/devin-acu-governor/web/dashboard-app/package-lock.json claude/devin-acu-governor/web/dashboard-app/vite.config.ts claude/devin-acu-governor/web/dashboard-app/src/components/UserTable.test.tsx claude/devin-acu-governor/web/dashboard-app/src/components/UserTable.tsx claude/devin-acu-governor/web/dashboard-app/src/app.css claude/devin-acu-governor/web/dashboard-app/README.md
git commit -m "fix(dag-dashboard): split email copy and detail actions"
git push -u origin HEAD
```

Expected: commit succeeds and branch pushes with upstream tracking.
