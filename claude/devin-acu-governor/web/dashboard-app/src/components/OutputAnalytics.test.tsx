import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { OutputAnalytics } from './OutputAnalytics'
import type { OutputAnalyticsInfo, UserRow } from '../types'

const user = {
  user_id: 'email|alice',
  email: 'alice@example.com',
  name: 'Alice Example',
  billing_org_id: 'platform',
  output: {
    loc_inserted: 42,
    loc_deleted: 8,
    net: 34,
    has_rows: true,
    daily: [],
    source_split: [{ source: 'CASCADE_CLIENT', loc_inserted: 42, loc_deleted: 8, net: 34 }],
    model_split: [{ model_uid: 'claude-sonnet-4-6', loc_inserted: 42, loc_deleted: 8, net: 34 }],
    ide_split: [{ ide: 'windsurf', loc_inserted: 42, loc_deleted: 8, net: 34 }],
    os_split: [{ os: 'darwin', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  },
} as unknown as UserRow

const analytics: OutputAnalyticsInfo = {
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
  daily: [{ date: '2026-06-15', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  source_split: [{ source: 'CASCADE_CLIENT', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  model_split: [{ model_uid: 'claude-sonnet-4-6', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  ide_split: [{ ide: 'windsurf', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  os_split: [{ os: 'darwin', loc_inserted: 42, loc_deleted: 8, net: 34 }],
  members: [{ user_id: user.user_id, email: user.email, name: user.name, billing_org_id: user.billing_org_id, output: user.output }],
  contributors: [],
  attribution: {
    matched: { loc_inserted: 42, loc_deleted: 8, net: 34 },
    unassigned: { loc_inserted: 0, loc_deleted: 0, net: 0 },
    matched_contributors: 1,
    unmatched_contributors: 0,
  },
}

describe('OutputAnalytics', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('shows totals, source split, freshness, and sortable member output', () => {
    render(<OutputAnalytics analytics={analytics} users={[user]} />)

    expect(screen.getByRole('heading', { name: 'Agent output' })).toBeInTheDocument()
    expect(screen.getByText('Accepted inserted')).toBeInTheDocument()
    expect(screen.getAllByText('42').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Desktop').length).toBeGreaterThan(0)
    expect(screen.getByText(/source data through 2026-06-16T03:00:00Z/)).toBeInTheDocument()
    expect(screen.getByText('Member-attributed estimates')).toBeInTheDocument()
    expect(screen.getByText('Alice Example')).toBeInTheDocument()
  })

  test('states unavailable output without presenting zero totals', () => {
    render(
      <OutputAnalytics
        analytics={{
          ...analytics,
          available: false,
          state: 'unavailable',
          reason: 'no_output_key',
          totals: null,
          members: [],
        }}
        users={[]}
      />,
    )

    expect(screen.getByText(/no Windsurf or Devin service key/)).toBeInTheDocument()
    expect(screen.queryByText('Accepted inserted')).not.toBeInTheDocument()
  })

  test('marks a previous successful snapshot stale', () => {
    render(<OutputAnalytics analytics={{ ...analytics, stale: true, state: 'stale' }} users={[user]} />)

    expect(screen.getByText('stale')).toBeInTheDocument()
    expect(screen.getByText(/last successful output snapshot/)).toBeInTheDocument()
  })

  test('identifies snapshots generated before output analytics existed', () => {
    render(
      <OutputAnalytics
        analytics={{ ...analytics, available: false, state: 'unavailable', reason: 'old_snapshot', totals: null }}
        users={[]}
      />,
    )

    expect(screen.getByText(/predates agent output analytics/)).toBeInTheDocument()
  })

  test('keeps roster rows without attributed output as unknown when only unassigned data exists', () => {
    render(
      <OutputAnalytics
        analytics={{
          ...analytics,
          members: [],
          attribution: {
            ...analytics.attribution!,
            matched: { loc_inserted: 0, loc_deleted: 0, net: 0 },
            unassigned: { loc_inserted: 10, loc_deleted: 2, net: 8 },
            unmatched_contributors: 1,
          },
        }}
        users={[{ ...user, output: null }]}
      />,
    )

    expect(screen.getByText('Alice Example')).toBeInTheDocument()
    expect(screen.queryByText('N/A')).not.toBeInTheDocument()
    expect(screen.getByText(/10 inserted \/ 2 deleted/)).toBeInTheDocument()
  })
})
