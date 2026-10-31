import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
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

  test('overview tab shows totals, source split, freshness, and attribution', () => {
    render(<OutputAnalytics analytics={analytics} users={[user]} />)

    expect(screen.getByRole('heading', { name: 'Agent output' })).toBeInTheDocument()
    expect(screen.getByText('Accepted inserted')).toBeInTheDocument()
    expect(screen.getAllByText('42').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Desktop').length).toBeGreaterThan(0)
    expect(screen.getByText(/source data through 2026-06-16T03:00:00Z/)).toBeInTheDocument()
    expect(screen.getByText('Member-attributed estimates')).toBeInTheDocument()
  })

  test('tab bar links every sub-page to its hash route', () => {
    render(<OutputAnalytics analytics={analytics} users={[user]} />)

    expect(screen.getByRole('link', { name: 'Overview' })).toHaveAttribute('href', '#/output')
    expect(screen.getByRole('link', { name: 'Daily' })).toHaveAttribute('href', '#/output/daily')
    expect(screen.getByRole('link', { name: 'Splits' })).toHaveAttribute('href', '#/output/splits')
    expect(screen.getByRole('link', { name: 'Members' })).toHaveAttribute('href', '#/output/members')
    expect(screen.getByRole('link', { name: 'Overview' })).toHaveAttribute('aria-current', 'page')
  })

  test('daily tab renders the daily list only', () => {
    render(<OutputAnalytics analytics={analytics} users={[user]} tab="daily" />)

    expect(screen.getByText('Daily output')).toBeInTheDocument()
    expect(screen.getByText('2026-06-15')).toBeInTheDocument()
    expect(screen.queryByText('Accepted inserted')).not.toBeInTheDocument()
  })

  test('splits tab renders model, IDE, and OS splits', () => {
    render(<OutputAnalytics analytics={analytics} users={[user]} tab="splits" />)

    expect(screen.getByText('Model split')).toBeInTheDocument()
    expect(screen.getByText('claude-sonnet-4-6')).toBeInTheDocument()
    expect(screen.getByText('IDE split')).toBeInTheDocument()
    expect(screen.getByText('OS split')).toBeInTheDocument()
  })

  test('members tab renders the sortable member output table', () => {
    render(<OutputAnalytics analytics={analytics} users={[user]} tab="members" />)

    expect(screen.getByText('Per-member accepted output')).toBeInTheDocument()
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
    const unassigned = {
      ...analytics,
      members: [],
      attribution: {
        ...analytics.attribution!,
        matched: { loc_inserted: 0, loc_deleted: 0, net: 0 },
        unassigned: { loc_inserted: 10, loc_deleted: 2, net: 8 },
        unmatched_contributors: 1,
      },
    }
    render(<OutputAnalytics analytics={unassigned} users={[{ ...user, output: null }]} />)
    expect(screen.getByText(/10 inserted \/ 2 deleted/)).toBeInTheDocument()
    cleanup()

    render(<OutputAnalytics analytics={unassigned} users={[{ ...user, output: null }]} tab="members" />)
    expect(screen.getByText('Alice Example')).toBeInTheDocument()
    expect(screen.queryByText('N/A')).not.toBeInTheDocument()
  })

  test('searches members by name, email, and id and reports an empty result', () => {
    const second = { ...user, user_id: 'user|second', email: 'second@example.com', name: 'Second Member' }
    render(<OutputAnalytics analytics={{ ...analytics, members: [user, second] }} users={[user, second]} tab="members" />)

    const search = screen.getByRole('textbox', { name: 'Search output members' })
    fireEvent.change(search, { target: { value: 'second member' } })
    expect(screen.getByText('Second Member')).toBeInTheDocument()
    expect(screen.queryByText('Alice Example')).not.toBeInTheDocument()
    fireEvent.change(search, { target: { value: 'second@example.com' } })
    expect(screen.getByText('Second Member')).toBeInTheDocument()
    fireEvent.change(search, { target: { value: 'USER|SECOND' } })
    expect(screen.getByText('Second Member')).toBeInTheDocument()
    fireEvent.change(search, { target: { value: 'no-match' } })
    expect(screen.getByText('No output members match the search.')).toBeInTheDocument()
  })

  test('renders net per Local Agent ACU, totals, null states, source order, and Details callback', () => {
    const makeOutput = (net: number, sourceSplit: OutputAnalyticsInfo['source_split'], hasRows = true) => ({
      ...user.output!,
      loc_inserted: Math.max(net, 0) + 20,
      loc_deleted: Math.max(-net, 0),
      net,
      has_rows: hasRows,
      source_split: sourceSplit,
    })
    const makeUser = (id: string, name: string, email: string, consumed: number, cascade: number, terminal: number, output: UserRow['output']): UserRow =>
      ({
        ...user,
        user_id: id,
        name,
        email,
        consumed,
        product_totals: { devin: 10, cascade, terminal, review: 0 },
        output,
      }) as UserRow
    const high = makeUser('user|high', 'High Ratio', 'high@example.com', 50, 1, 1, makeOutput(20, [
      { source: 'CHISEL', loc_inserted: 4, loc_deleted: 0, net: 4 },
      { source: 'CASCADE_CLIENT', loc_inserted: 16, loc_deleted: 0, net: 16 },
    ]))
    const low = makeUser('user|low', 'Low Ratio', 'low@example.com', 60, 5, 5, makeOutput(20, [
      { source: 'CASCADE_CLIENT', loc_inserted: 20, loc_deleted: 0, net: 20 },
    ]))
    const negative = makeUser('user|negative', 'Negative Net', 'negative@example.com', 30, 1, 1, makeOutput(-3, []))
    const zero = makeUser('user|zero', 'Zero Agent', 'zero@example.com', 20, 0, 0, makeOutput(4, []))
    const missing = makeUser('user|missing', 'Missing Output', 'missing@example.com', 20, 2, 0, null)
    const onSelectUser = vi.fn()
    const members = [high, low, negative, zero, missing].map((candidate) => ({
      user_id: candidate.user_id,
      email: candidate.email,
      name: candidate.name,
      billing_org_id: candidate.billing_org_id,
      output: candidate.output ?? null,
    }))

    render(<OutputAnalytics analytics={{ ...analytics, members }} users={[high, low, negative, zero, missing]} tab="members" onSelectUser={onSelectUser} />)

    const highRow = screen.getByRole('row', { name: /High Ratio/ })
    expect(within(highRow).getByText('50')).toBeInTheDocument()
    expect(within(highRow).getByText('2')).toBeInTheDocument()
    expect(within(highRow).getByText('10')).toBeInTheDocument()
    expect(within(highRow).getByText('4 / 16')).toBeInTheDocument()
    const lowRow = screen.getByRole('row', { name: /Low Ratio/ })
    expect(within(lowRow).getByText('60')).toBeInTheDocument()
    expect(within(lowRow).getByText('10')).toBeInTheDocument()
    expect(within(lowRow).getByText('2')).toBeInTheDocument()
    expect(within(lowRow).getByText('0 / 20')).toBeInTheDocument()
    expect(within(screen.getByRole('row', { name: /Negative Net/ })).getByText('-1.5')).toBeInTheDocument()
    expect(within(screen.getByRole('row', { name: /Zero Agent/ })).getByText('—')).toBeInTheDocument()
    expect(within(screen.getByRole('row', { name: /Missing Output/ })).getAllByText('—').length).toBeGreaterThan(0)
    fireEvent.click(within(highRow).getByRole('button', { name: /Open details/ }))
    expect(onSelectUser).toHaveBeenCalledWith(high)

    cleanup()
    render(<OutputAnalytics analytics={{ ...analytics, members }} users={[high, low, negative, zero, missing]} tab="members" />)
    expect(within(screen.getByRole('row', { name: /High Ratio/ })).getByRole('button', { name: /Open details/ })).toBeDisabled()
  })

  test('switches to distinct previous output and usage without falling back to current values', () => {
    const previous = {
      ...analytics,
      start_date: '2026-04-16',
      end_date: '2026-05-15',
      totals: { loc_inserted: 9, loc_deleted: 2, net: 7 },
      members: [{
        ...user,
        output: {
          ...user.output!,
          loc_inserted: 9,
          loc_deleted: 2,
          net: 7,
          source_split: [{ source: 'CHISEL', loc_inserted: 9, loc_deleted: 2, net: 7 }],
          model_split: [{ model_uid: 'previous-model', loc_inserted: 9, loc_deleted: 2, net: 7 }],
          ide_split: [{ ide: 'cli', loc_inserted: 9, loc_deleted: 2, net: 7 }],
          os_split: [{ os: 'darwin', loc_inserted: 9, loc_deleted: 2, net: 7 }],
        },
      }],
    }
    render(
      <OutputAnalytics
        analytics={analytics}
        previousAnalytics={previous}
        prev={{
          available: true,
          reason: null,
          cycle: { after: 1, before: 2, start_date: '2026-04-16', end_date: '2026-05-15', cycle_days: 30 },
          enterprise: { consumed: 99, daily: [] },
          users: [{ user_id: user.user_id, consumed: 11, products: { devin: 2, cascade: 3, terminal: 1, review: 0 } }],
        }}
        users={[user]}
        tab="members"
      />,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Last month' }))
    expect(screen.getByText('Previous billing cycle: 2026-04-16 → 2026-05-15')).toBeInTheDocument()
    expect(screen.getByText('Previous billing-cycle member output')).toBeInTheDocument()
    const row = screen.getByRole('row', { name: /Alice Example/ })
    expect(within(row).getByText('11')).toBeInTheDocument()
    expect(within(row).getByText('4')).toBeInTheDocument()
    expect(within(row).getByText('7')).toBeInTheDocument()
    expect(row).not.toHaveTextContent('34')
  })

  test('opens member Details and shows unavailable historical state explicitly', () => {
    const onSelectUser = vi.fn()
    render(<OutputAnalytics analytics={analytics} users={[user]} tab="members" onSelectUser={onSelectUser} />)
    fireEvent.click(screen.getByRole('button', { name: /Open details for Alice/ }))
    expect(onSelectUser).toHaveBeenCalledWith(user)

    fireEvent.click(screen.getByRole('button', { name: 'Last month' }))
    expect(screen.getByText(/Unavailable: missing_previous_snapshot/)).toBeInTheDocument()
    expect(screen.queryByText('Alice Example')).not.toBeInTheDocument()
  })
})
