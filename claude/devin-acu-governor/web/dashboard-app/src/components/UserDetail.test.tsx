import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { UserDetail } from './UserDetail'
import type { CycleInfo, ModelAnalyticsInfo, OrgRow, UserRow } from '../types'

// jsdom has no ResizeObserver; recharts' ResponsiveContainer needs one.
vi.stubGlobal(
  'ResizeObserver',
  class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
)

const cycle: CycleInfo = {
  after: 1778918400,
  before: 1781596800,
  start_date: '2026-05-16',
  end_date: '2026-06-15',
  cycle_days: 31,
  elapsed_days: 10,
  left_days: 21,
}

const modelAnalytics: ModelAnalyticsInfo = {
  available: false,
  stale: false,
  reason: null,
  fetched_at: null,
  fetched_at_epoch: null,
  start_date: null,
  end_date: null,
}

const platformOrg: OrgRow = {
  org_id: 'org_8f3a91',
  name: 'Platform Engineering',
  consumed: 500,
  daily_run_rate: 50,
  projected: 1550,
  max_session_acu_limit: 100,
  products: { devin: 100, cascade: 300, terminal: 80, review: 20 },
  local: { consumed: 380, limit: 1000, daily_run_rate: 38, projected: 1178, pct_limit: 0.38, status: 'ok' },
  cloud: { consumed: 100, limit: 500, daily_run_rate: 10, projected: 310, pct_limit: 0.2, status: 'ok' },
  status: 'ok',
}

const alice: UserRow = {
  user_id: 'email|alice',
  email: 'alice@example.com',
  name: 'Alice Example',
  consumed: 42,
  explicit_cycle_acu_limit: 100,
  default_cycle_acu_limit: 200,
  effective_cycle_acu_limit: 100,
  cap_source: 'explicit',
  billing_org_id: 'org_8f3a91',
  headroom: 58,
  pct_limit: 0.42,
  status: 'ok',
  daily: [],
  product_totals: { devin: 40, cascade: 1, terminal: 1, review: 0 },
  sessions: { count: 2, acus: 12 },
  models: [],
  ides: [],
}

describe('UserDetail billing org line', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('shows org name with the id alongside', () => {
    render(
      <UserDetail user={alice} cycle={cycle} modelAnalytics={modelAnalytics} orgs={[platformOrg]} onClose={vi.fn()} />,
    )

    expect(screen.getByText('org: Platform Engineering (org_8f3a91)')).toBeInTheDocument()
  })

  test('falls back to the raw id when no org matches', () => {
    render(<UserDetail user={alice} cycle={cycle} modelAnalytics={modelAnalytics} orgs={[]} onClose={vi.fn()} />)

    expect(screen.getByText('org: org_8f3a91')).toBeInTheDocument()
  })

  test('omits the org line for users without a billing org', () => {
    const nomad: UserRow = { ...alice, billing_org_id: null }
    render(
      <UserDetail user={nomad} cycle={cycle} modelAnalytics={modelAnalytics} orgs={[platformOrg]} onClose={vi.fn()} />,
    )

    expect(screen.queryByText(/^org:/)).not.toBeInTheDocument()
  })
})
