import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import App from './App'
import type { DashboardData, OrgRow, UserRow } from './types'

const dashboardHook = vi.hoisted(() => ({ useDashboardData: vi.fn() }))
vi.mock('./useDashboardData', () => dashboardHook)

vi.mock('./components/OutputAnalytics', () => ({
  OutputAnalytics: ({
    period,
    onPeriodChange,
    onSelectUser,
    users,
  }: {
    period: 'current' | 'previous'
    onPeriodChange: (period: 'current' | 'previous') => void
    onSelectUser: (user: UserRow) => void
    users: UserRow[]
  }) => (
    <div>
      <button type="button" onClick={() => onPeriodChange('previous')}>Previous output</button>
      <button type="button" onClick={() => onSelectUser(users[0])}>Select output user</button>
      <span>output period: {period}</span>
    </div>
  ),
}))

vi.mock('./components/UserTable', () => ({
  UserTable: ({ users, onSelect }: { users: UserRow[]; onSelect: (user: UserRow) => void }) => (
    <button type="button" onClick={() => onSelect(users[0])}>Select users user</button>
  ),
}))

vi.mock('./components/OrgDetail', () => ({
  OrgDetail: ({ users, onSelectUser }: { users: UserRow[]; onSelectUser: (user: UserRow) => void }) => (
    <button type="button" onClick={() => onSelectUser(users[0])}>Select org user</button>
  ),
}))

vi.mock('./components/UserDetail', () => ({
  UserDetail: ({ outputPeriod }: { outputPeriod: 'current' | 'previous' }) => <div>drawer period: {outputPeriod}</div>,
}))

vi.stubGlobal(
  'ResizeObserver',
  class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
)

const user = {
  user_id: 'email|alice',
  email: 'alice@example.com',
  name: 'Alice Example',
  consumed: 10,
  product_totals: { devin: 0, cascade: 1, terminal: 1, review: 0 },
  billing_org_id: 'platform',
  daily: [],
  models: [],
  ides: [],
  sessions: null,
  status: 'ok',
  cap_source: 'uncapped',
  explicit_cycle_acu_limit: null,
  default_cycle_acu_limit: null,
  effective_cycle_acu_limit: null,
  headroom: null,
  pct_limit: null,
} as unknown as UserRow

const org = {
  org_id: 'platform',
  name: 'Platform',
  consumed: 10,
  daily_run_rate: 1,
  projected: 10,
  max_session_acu_limit: null,
  products: { devin: 0, cascade: 1, terminal: 1, review: 0 },
  local: { consumed: 2, limit: null, daily_run_rate: 1, projected: 2, pct_limit: null, status: 'uncapped' },
  cloud: { consumed: 0, limit: 0, daily_run_rate: 0, projected: 0, pct_limit: null, status: 'cloud_off' },
  status: 'uncapped',
} as unknown as OrgRow

const data = {
  generated_at: '2026-06-16T04:00:00Z',
  refresh: { enabled: false, interval_minutes: null, interval_ms: null },
  cycle: {
    after: 1778918400,
    before: 1781596800,
    start_date: '2026-05-16',
    end_date: '2026-06-15',
    cycle_days: 31,
    elapsed_days: 30,
    left_days: 1,
  },
  pool: 24000,
  enterprise: { consumed: 10, remaining: 23990, daily_run_rate: 1, projected_cycle_total: 10, projected_over_under: 23990, verdict: 'UNDER' },
  cap_totals: { effective_user_cycle_acu_limit: 0, capped_users: 0, uncapped_users: 1, zero_cap_users: 0 },
  product_split: [],
  daily: [],
  sessions_info: { available: false, count: 0, acus: 0 },
  model_analytics: { available: false, stale: false, reason: null, fetched_at: null, fetched_at_epoch: null, start_date: null, end_date: null },
  output_analytics: { available: false, stale: false, state: 'unavailable', reason: 'no_output_key', members: [] },
  prev_cycle: { available: false, reason: 'no_previous_cycle', cycle: null, enterprise: null, users: [] },
  orgs: [org],
  attribution: { org_attributed: 10, unattributed: 0, pct_unattributed: 0 },
  users: [user],
  warnings: [],
} as unknown as DashboardData

function mockHook() {
  dashboardHook.useDashboardData.mockReturnValue({
    data,
    error: null,
    stale: false,
    status: { state: 'static', pct: 100, phase: '', detail: '', interval_seconds: 0, next_refresh_epoch: null, updated_at_epoch: 0, generated_at: data.generated_at },
    manualRefreshing: false,
    refreshNow: vi.fn(),
  })
}

describe('App output period context', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    window.location.hash = ''
  })

  test('resets to current output when opening a user from Users', async () => {
    mockHook()
    window.location.hash = '#/output/members'
    render(<App />)

    fireEvent.click(screen.getByRole('button', { name: 'Previous output' }))
    fireEvent.click(screen.getByRole('button', { name: 'Select output user' }))
    expect(screen.getByText('drawer period: previous')).toBeInTheDocument()

    window.location.hash = '#/users'
    fireEvent(window, new HashChangeEvent('hashchange'))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Select users user' })).toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: 'Select users user' }))
    expect(screen.getByText('drawer period: current')).toBeInTheDocument()
  })

  test('resets to current output when opening a user from an Org page', async () => {
    mockHook()
    window.location.hash = '#/output/members'
    render(<App />)

    fireEvent.click(screen.getByRole('button', { name: 'Previous output' }))
    fireEvent.click(screen.getByRole('button', { name: 'Select output user' }))
    window.location.hash = '#/org/platform'
    fireEvent(window, new HashChangeEvent('hashchange'))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Select org user' })).toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: 'Select org user' }))
    expect(screen.getByText('drawer period: current')).toBeInTheDocument()
  })
})
