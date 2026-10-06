import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { OrgDetail } from './OrgDetail'
import { UserDetail } from './UserDetail'
import type { CycleInfo, ModelAnalyticsInfo, OrgRow, OutputAnalyticsInfo, UserRow, UserOutput } from '../types'

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
  elapsed_days: 30,
  left_days: 1,
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

const output: UserOutput = {
  loc_inserted: 42,
  loc_deleted: 8,
  net: 34,
  has_rows: true,
  daily: [{ date: '2026-06-15', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  source_split: [{ source: 'CASCADE_CLIENT', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  model_split: [
    { model_uid: 'claude-sonnet-4-6', loc_inserted: 42, loc_deleted: 8, net: 34 },
    { model_uid: 'delete-heavy', loc_inserted: 2, loc_deleted: 5, net: -3 },
  ],
  ide_split: [{ ide: 'windsurf', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  os_split: [{ os: 'darwin', loc_inserted: 42, loc_deleted: 8, net: 34 }],
}

const outputAnalytics: OutputAnalyticsInfo = {
  available: true,
  stale: false,
  state: 'fresh',
  reason: null,
  fetched_at: '2026-06-16T04:00:00Z',
  fetched_at_epoch: 1781582400,
  data_freshness: '2026-06-16T03:00:00Z',
  data_freshness_epoch: 1781578800,
  start_date: '2026-05-16',
  end_date: '2026-06-15',
  team_id: 'team_fixture',
  group_id: null,
  key_source: 'cog',
  rows: [],
  totals: { loc_inserted: 42, loc_deleted: 8, net: 34 },
  daily: output.daily,
  source_split: output.source_split,
  model_split: output.model_split,
  ide_split: output.ide_split,
  os_split: output.os_split,
  members: [],
  contributors: [],
  attribution: {
    matched: { loc_inserted: 42, loc_deleted: 8, net: 34 },
    unassigned: { loc_inserted: 0, loc_deleted: 0, net: 0 },
    matched_contributors: 1,
    unmatched_contributors: 0,
  },
}

const user: UserRow = {
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
  sessions: null,
  models: [],
  ides: [],
  output,
}

const org: OrgRow = {
  org_id: 'platform',
  name: 'Platform',
  consumed: 42,
  daily_run_rate: 1.4,
  projected: 43.4,
  max_session_acu_limit: null,
  products: { devin: 40, cascade: 1, terminal: 1, review: 0 },
  local: { consumed: 2, limit: 100, daily_run_rate: 0.1, projected: 3, pct_limit: 0.02, status: 'ok' },
  cloud: { consumed: 40, limit: 100, daily_run_rate: 1.3, projected: 41, pct_limit: 0.4, status: 'ok' },
  status: 'ok',
  output,
  daily: [],
  sessions: null,
}

describe('output detail views', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('user drawer presents accepted LoC and all output dimensions', () => {
    render(
      <UserDetail
        user={user}
        cycle={cycle}
        modelAnalytics={modelAnalytics}
        outputAnalytics={outputAnalytics}
        orgs={[org]}
        onClose={vi.fn()}
      />,
    )

    expect(screen.getByText('Accepted agent output')).toBeInTheDocument()
    expect(screen.getByText('Accepted inserted')).toBeInTheDocument()
    expect(screen.getByText('Desktop')).toBeInTheDocument()
    expect(screen.getByText('claude-sonnet-4-6')).toBeInTheDocument()
    expect(screen.getByText('-3 net')).toBeInTheDocument()
    expect(screen.getByText('-3 net').parentElement?.querySelector('i')?.getAttribute('style')).not.toContain('-')
    expect(screen.getByText('darwin')).toBeInTheDocument()
  })

  test('org detail labels LoC as member-attributed estimate', () => {
    render(
      <OrgDetail
        org={org}
        users={[user]}
        cycle={cycle}
        cloudSessions={undefined}
        modelAnalytics={modelAnalytics}
        outputAnalytics={outputAnalytics}
        onBack={vi.fn()}
        onSelectUser={vi.fn()}
      />,
    )

    expect(screen.getByText('Accepted agent output')).toBeInTheDocument()
    expect(screen.getByText(/Member-attributed estimate; API output is team-scoped/)).toBeInTheDocument()
    expect(screen.getByText('Desktop')).toBeInTheDocument()
    expect(screen.getByText('Local Agent models')).toBeInTheDocument()
    expect(screen.getByText('Local Agent activity — per member, all models')).toBeInTheDocument()
  })

  test('empty output state does not imply zero accepted lines in details', () => {
    const emptyAnalytics = { ...outputAnalytics, state: 'no_data' as const, reason: 'no_data', totals: { loc_inserted: 0, loc_deleted: 0, net: 0 } }
    render(
      <UserDetail
        user={{ ...user, output: null }}
        cycle={cycle}
        modelAnalytics={modelAnalytics}
        outputAnalytics={emptyAnalytics}
        orgs={[org]}
        onClose={vi.fn()}
      />,
    )

    expect(screen.getByText('no output attribution available for this member')).toBeInTheDocument()
    expect(screen.queryByText('Accepted inserted')).not.toBeInTheDocument()

    cleanup()
    render(
      <OrgDetail
        org={{ ...org, output: null }}
        users={[user]}
        cycle={cycle}
        cloudSessions={undefined}
        modelAnalytics={modelAnalytics}
        outputAnalytics={emptyAnalytics}
        onBack={vi.fn()}
        onSelectUser={vi.fn()}
      />,
    )
    expect(screen.getByText('no member-attributed output available for this organization')).toBeInTheDocument()
  })
})
