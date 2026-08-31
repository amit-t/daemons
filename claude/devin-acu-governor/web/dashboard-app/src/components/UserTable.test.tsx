import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { UserTable } from './UserTable'
import type { OrgRow, UserRow } from '../types'

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
  daily_run_rate: 1.4,
  projected: 43.4,
  forecast: 'under',
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
  const user = userEvent.setup()
  Object.defineProperty(navigator, 'clipboard', {
    value: { writeText },
    configurable: true,
  })
  render(<UserTable users={[alice]} orgs={[platformOrg]} onSelect={onSelect} />)
  return { onSelect, writeText, user }
}

describe('UserTable explicit email/detail actions', () => {
  beforeEach(() => {
    vi.useRealTimers()
  })

  afterEach(() => {
    cleanup()
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

    await waitFor(() => expect(writeText).toHaveBeenCalledWith('alice@example.com'))
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

describe('UserTable donor status', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  // A recorded current-cycle donor whose cap DAG reduced (raw over, low real
  // usage) is rendered with the 'donor' badge + filter chip, not 'over'.
  const donorRow: UserRow = {
    ...alice,
    user_id: 'email|dana',
    email: 'dana@example.com',
    name: 'Dana Donor',
    consumed: 1,
    effective_cycle_acu_limit: 1,
    headroom: 0,
    pct_limit: 1,
    status: 'donor',
    raw_status: 'over',
    donor: { baseline_cap: 500, given_total: 250, last_given_at: null, suppressed: true },
  }

  test('donor status renders badge and filter chip', () => {
    render(<UserTable users={[alice, donorRow]} orgs={[platformOrg]} onSelect={vi.fn()} />)

    expect(screen.getByRole('button', { name: 'donor (1)' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'over (1)' })).not.toBeInTheDocument()
    const badge = screen.getByText('donor', { selector: 'span.badge' })
    expect(badge).toHaveClass('badge-donor')
  })
})

describe('UserTable billing org column', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('renders the org name, not the org id', () => {
    render(<UserTable users={[alice]} orgs={[platformOrg]} onSelect={vi.fn()} />)

    const link = screen.getByRole('link', { name: 'Platform Engineering' })
    expect(link).toBeInTheDocument()
    // The id stays reachable: tooltip carries it, link opens the org page.
    expect(link).toHaveAttribute('title', expect.stringContaining('org_8f3a91'))
    expect(link).toHaveAttribute('href', '#/org/org_8f3a91')
    // The raw id is no longer printed in the cell.
    expect(screen.queryByText('org_8f3a91')).not.toBeInTheDocument()
  })

  test('falls back to the raw id when no org in snapshot matches', () => {
    const orphan: UserRow = { ...alice, user_id: 'email|bob', email: 'bob@example.com', billing_org_id: 'org_gone' }
    render(<UserTable users={[orphan]} orgs={[platformOrg]} onSelect={vi.fn()} />)

    expect(screen.getByText('org_gone')).toBeInTheDocument()
  })

  test('renders a dash for users without a billing org', () => {
    const nomad: UserRow = { ...alice, user_id: 'email|eve', email: 'eve@example.com', billing_org_id: null }
    render(<UserTable users={[nomad]} orgs={[platformOrg]} onSelect={vi.fn()} />)

    expect(screen.getAllByText('—').length).toBeGreaterThan(0)
    expect(screen.queryByRole('link')).not.toBeInTheDocument()
  })

  test('search filter matches the org name and the org id', async () => {
    const user = userEvent.setup()
    render(<UserTable users={[alice]} orgs={[platformOrg]} onSelect={vi.fn()} />)
    const search = screen.getByPlaceholderText('filter by name / email / org…')

    await user.type(search, 'platform eng')
    expect(screen.getByText('alice@example.com')).toBeInTheDocument()

    await user.clear(search)
    await user.type(search, 'org_8f3a91')
    expect(screen.getByText('alice@example.com')).toBeInTheDocument()

    await user.clear(search)
    await user.type(search, 'no-such-org')
    expect(screen.queryByText('alice@example.com')).not.toBeInTheDocument()
  })

  test('clicking the org link does not open the user detail drawer', async () => {
    const onSelect = vi.fn()
    const user = userEvent.setup()
    render(<UserTable users={[alice]} orgs={[platformOrg]} onSelect={onSelect} />)

    await user.click(screen.getByRole('link', { name: 'Platform Engineering' }))

    expect(onSelect).not.toHaveBeenCalled()
  })
})

describe('UserTable forecast column', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('renders projected value and colored forecast badge', () => {
    render(<UserTable users={[alice]} orgs={[platformOrg]} onSelect={vi.fn()} />)

    expect(screen.getByText('Projected')).toBeInTheDocument()
    expect(screen.getByText('Forecast')).toBeInTheDocument()
    expect(screen.getByText('43.4')).toBeInTheDocument()
    const badge = screen.getByText('under', { selector: 'span.badge' })
    expect(badge).toHaveClass('badge-ok')
  })

  test('forecast over renders the dashed forecast_over palette', () => {
    const hot: UserRow = {
      ...alice,
      user_id: 'email|hot',
      email: 'hot@example.com',
      projected: 180,
      forecast: 'over',
    }
    render(<UserTable users={[hot]} orgs={[platformOrg]} onSelect={vi.fn()} />)

    const badge = screen.getByText('over', { selector: 'span.badge' })
    expect(badge).toHaveClass('badge-forecast_over')
  })

  // data.json snapshots generated before the forecast column carry no
  // projected/forecast fields — cells degrade to '—', nothing crashes.
  test('legacy snapshot without forecast fields renders dashes', () => {
    const legacy: UserRow = { ...alice }
    delete legacy.daily_run_rate
    delete legacy.projected
    delete legacy.forecast
    render(<UserTable users={[legacy]} orgs={[platformOrg]} onSelect={vi.fn()} />)

    expect(screen.queryByText('under', { selector: 'span.badge' })).not.toBeInTheDocument()
    expect(screen.getAllByText('—').length).toBeGreaterThan(0)
  })
})
