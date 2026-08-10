import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { OrgDetail } from './OrgDetail'
import type { CloudSessionsInfo, CycleInfo, ModelAnalyticsInfo, OrgRow, UserRow } from '../types'

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

const org: OrgRow = {
  org_id: 'platform',
  name: 'Platform',
  consumed: 500,
  daily_run_rate: 50,
  projected: 1550,
  max_session_acu_limit: 100,
  products: { devin: 100, cascade: 300, terminal: 80, review: 20 },
  local: { consumed: 380, limit: 1000, daily_run_rate: 38, projected: 1178, pct_limit: 0.38, status: 'ok' },
  cloud: { consumed: 100, limit: 500, daily_run_rate: 10, projected: 310, pct_limit: 0.2, status: 'ok' },
  status: 'ok',
  daily: [
    { date: '2026-06-01', epoch: 1780272000, acus: 500, devin: 100, cascade: 300, terminal: 80, review: 20 },
  ],
  sessions: { count: 3, acus: 15.5 },
}

function makeUser(over: Partial<UserRow>): UserRow {
  return {
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
    sessions: { count: 2, acus: 12.5 },
    models: [{ model: 'claude-sonnet-4-6', acus: 2, messages: 37 }],
    ides: [],
    ...over,
  }
}

const modelAnalytics: ModelAnalyticsInfo = {
  available: true,
  stale: false,
  reason: null,
  fetched_at: '2026-08-08T10:00:00Z',
  fetched_at_epoch: 1786528800,
  start_date: '2026-07-16',
  end_date: '2026-08-16',
}

const alice = makeUser({})
const bob = makeUser({
  user_id: 'email|bob',
  email: 'bob@example.com',
  name: 'Bob Example',
  billing_org_id: 'research',
})

const cloudSessions: CloudSessionsInfo = {
  available: true,
  items: [
    {
      session_id: 's-alice-1',
      url: 'https://app.devin.ai/sessions/s-alice-1',
      title: 'Fix flaky CI',
      status: 'exit',
      status_detail: null,
      user_id: 'email|alice',
      service_user_id: null,
      org_id: 'platform',
      created_at: 1781000000,
      updated_at: 1781003600,
      acus_consumed: 10.5,
      origin: 'webapp',
      category: null,
      subcategory: null,
      is_archived: false,
      playbook_id: null,
      tags: [],
      pull_requests: [],
    },
    {
      session_id: 's-svc-1',
      url: null,
      title: 'Nightly dependency bump',
      status: 'exit',
      status_detail: null,
      user_id: null,
      service_user_id: 'svc|nightly-ci',
      org_id: 'platform',
      created_at: 1781300000,
      updated_at: 1781303000,
      acus_consumed: 3,
      origin: 'api',
      category: null,
      subcategory: null,
      is_archived: false,
      playbook_id: null,
      tags: [],
      pull_requests: [],
    },
    {
      session_id: 's-bob-1',
      url: null,
      title: 'Write API docs',
      status: 'suspended',
      status_detail: null,
      user_id: 'email|bob',
      service_user_id: null,
      org_id: 'research',
      created_at: 1781200000,
      updated_at: 1781205000,
      acus_consumed: 5,
      origin: 'api',
      category: null,
      subcategory: null,
      is_archived: false,
      playbook_id: null,
      tags: [],
      pull_requests: [],
    },
  ],
}

function setup(overrides?: { cloudSessions?: CloudSessionsInfo | undefined }) {
  const onBack = vi.fn()
  const onSelectUser = vi.fn()
  const user = userEvent.setup()
  render(
    <OrgDetail
      org={org}
      users={[alice, bob]}
      cycle={cycle}
      cloudSessions={overrides && 'cloudSessions' in overrides ? overrides.cloudSessions : cloudSessions}
      modelAnalytics={modelAnalytics}
      onBack={onBack}
      onSelectUser={onSelectUser}
    />,
  )
  return { onBack, onSelectUser, user }
}

describe('OrgDetail page', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('members table shows only users with this billing_org_id', () => {
    setup()
    expect(screen.getByText('Alice Example')).toBeInTheDocument()
    expect(screen.queryByText('Bob Example')).not.toBeInTheDocument()
  })

  test('sessions table shows only this org, service sessions included', () => {
    setup()
    expect(screen.getByText('Fix flaky CI')).toBeInTheDocument()
    expect(screen.getByText('Nightly dependency bump')).toBeInTheDocument()
    expect(screen.getByText('svc|nightly-ci (service)')).toBeInTheDocument()
    expect(screen.queryByText('Write API docs')).not.toBeInTheDocument()
  })

  test('session owner resolves to member email', () => {
    setup()
    // alice appears once in the members table (CopyEmail) and once as session owner
    expect(screen.getAllByText('alice@example.com').length).toBeGreaterThanOrEqual(2)
  })

  test('search filters the session rows', async () => {
    const { user } = setup()
    await user.type(screen.getByPlaceholderText(/filter by title/i), 'flaky')
    expect(screen.getByText('Fix flaky CI')).toBeInTheDocument()
    expect(screen.queryByText('Nightly dependency bump')).not.toBeInTheDocument()
  })

  test('member Details button opens the user drawer', async () => {
    const { onSelectUser, user } = setup()
    await user.click(screen.getByRole('button', { name: 'Open details for alice@example.com' }))
    expect(onSelectUser).toHaveBeenCalledWith(alice)
  })

  test('back button fires onBack', async () => {
    const { onBack, user } = setup()
    await user.click(screen.getByRole('button', { name: '← console' }))
    expect(onBack).toHaveBeenCalledTimes(1)
  })

  test('local agent activity lists members with cascade/terminal burn', () => {
    setup()
    expect(screen.getByText(/Local Agent activity/)).toBeInTheDocument()
    // alice has 2 local ACUs (cascade 1 + terminal 1) and 37 analytics messages;
    // "37 msg" shows in both the member activity bar and the model bar
    expect(screen.getAllByText('37 msg').length).toBe(2)
    expect(screen.getByText(/no session-list API/)).toBeInTheDocument()
  })

  test('org model split aggregates member models', () => {
    setup()
    expect(screen.getByText('Local Agent models')).toBeInTheDocument()
    expect(screen.getByText('claude-sonnet-4-6')).toBeInTheDocument()
  })

  test('old snapshot without cloud_sessions shows the regenerate hint', () => {
    setup({ cloudSessions: undefined })
    expect(screen.getByText(/session list not in this snapshot/)).toBeInTheDocument()
  })

  test('sessions API unavailable shows the degraded hint', () => {
    setup({ cloudSessions: { available: false, items: [] } })
    expect(screen.getByText(/sessions API unavailable when this snapshot/)).toBeInTheDocument()
  })
})
