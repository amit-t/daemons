import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import App from './App'
import type { DashboardData } from './types'

const dashboardHook = vi.hoisted(() => ({ useDashboardData: vi.fn() }))
vi.mock('./useDashboardData', () => dashboardHook)

vi.stubGlobal(
  'ResizeObserver',
  class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
)

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
  enterprise: {
    consumed: 0,
    remaining: 24000,
    daily_run_rate: 0,
    projected_cycle_total: 0,
    projected_over_under: 24000,
    verdict: 'UNDER',
  },
  cap_totals: { effective_user_cycle_acu_limit: 0, capped_users: 0, uncapped_users: 0, zero_cap_users: 0 },
  product_split: [],
  daily: [],
  sessions_info: { available: false, count: 0, acus: 0 },
  model_analytics: {
    available: false,
    stale: false,
    reason: null,
    fetched_at: null,
    fetched_at_epoch: null,
    start_date: null,
    end_date: null,
  },
  output_analytics: {
    available: false,
    stale: false,
    state: 'unavailable',
    reason: 'no_output_key',
    fetched_at: null,
    fetched_at_epoch: null,
    data_freshness: null,
    data_freshness_epoch: null,
    start_date: null,
    end_date: null,
    team_id: null,
    group_id: null,
    key_source: null,
    rows: [],
    totals: null,
    daily: [],
    source_split: [],
    model_split: [],
    ide_split: [],
    os_split: [],
    members: [],
    contributors: [],
    attribution: null,
  },
  orgs: [],
  attribution: { org_attributed: 0, unattributed: 0, pct_unattributed: null },
  users: [],
  warnings: [],
} as unknown as DashboardData

describe('agent output navigation', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    window.location.hash = ''
  })

  test('console exposes a visible anchor to the output section', () => {
    dashboardHook.useDashboardData.mockReturnValue({
      data,
      error: null,
      stale: false,
      status: { state: 'static', pct: 100, phase: '', detail: '', interval_seconds: 0, next_refresh_epoch: null, updated_at_epoch: 0, generated_at: data.generated_at },
      manualRefreshing: false,
      refreshNow: vi.fn(),
    })

    render(<App />)

    const link = screen.getByRole('link', { name: /agent output/i })
    expect(link).toHaveAttribute('href', '#agent-output')
    expect(document.getElementById('agent-output')).toBeInTheDocument()
  })
})
