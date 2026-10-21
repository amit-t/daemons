import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen, fireEvent } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { LastMonth } from './LastMonth'
import type { CycleInfo, PrevCycleInfo, UserRow } from '../types'

const cycle: CycleInfo = {
  after: 1778918400,
  before: 1781596800,
  start_date: '2026-05-16',
  end_date: '2026-06-16',
  cycle_days: 31,
  elapsed_days: 30,
  left_days: 1,
}

const prev: PrevCycleInfo = {
  available: true,
  reason: null,
  cycle: { after: 1776326400, before: 1778918400, start_date: '2026-04-16', end_date: '2026-05-16', cycle_days: 30 },
  enterprise: { consumed: 1300, daily: [] },
  users: [
    { user_id: 'email|alice', consumed: 100, products: { devin: 30, cascade: 50, terminal: 20, review: 0 } },
    { user_id: 'email|bob', consumed: 40, products: { devin: 0, cascade: 40, terminal: 0, review: 0 } },
  ],
}

function user(partial: Partial<UserRow>): UserRow {
  return {
    user_id: 'u',
    email: 'u@example.com',
    name: 'U',
    consumed: 0,
    explicit_cycle_acu_limit: null,
    default_cycle_acu_limit: null,
    effective_cycle_acu_limit: null,
    cap_source: 'uncapped',
    billing_org_id: null,
    headroom: null,
    pct_limit: null,
    status: 'ok',
    daily: [],
    product_totals: { devin: 0, cascade: 0, terminal: 0, review: 0 },
    sessions: null,
    models: [],
    ides: [],
    ...partial,
  } as UserRow
}

const users = [
  user({ user_id: 'email|alice', email: 'alice@example.com', name: 'Alice', consumed: 60, projected: 124 }),
  user({ user_id: 'email|bob', email: 'bob@example.com', name: 'Bob', consumed: 10, projected: 20 }),
]

describe('LastMonth', () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('renders the previous-cycle window, cards, and comparison rows', () => {
    render(<LastMonth prev={prev} users={users} cycle={cycle} enterpriseConsumed={900} onSelectUser={vi.fn()} />)

    expect(screen.getByText(/2026-04-16 → 2026-05-16/)).toBeInTheDocument()
    expect(screen.getByText('Last month total')).toBeInTheDocument()
    expect(screen.getByText('1,300')).toBeInTheDocument()
    expect(screen.getByText('Alice')).toBeInTheDocument()
    expect(screen.getByText('100')).toBeInTheDocument()
    expect(screen.getByText(/\+24/)).toBeInTheDocument()
  })

  test('search filters by email or name', () => {
    render(<LastMonth prev={prev} users={users} cycle={cycle} enterpriseConsumed={900} onSelectUser={vi.fn()} />)

    fireEvent.change(screen.getByLabelText('Search users'), { target: { value: 'bob' } })
    expect(screen.queryByText('Alice')).not.toBeInTheDocument()
    expect(screen.getByText('Bob')).toBeInTheDocument()
    expect(screen.getByText(/1 of 2 users/)).toBeInTheDocument()
  })

  test('details button opens the user drawer via onSelectUser', () => {
    const onSelect = vi.fn()
    render(<LastMonth prev={prev} users={users} cycle={cycle} enterpriseConsumed={900} onSelectUser={onSelect} />)

    fireEvent.click(screen.getByRole('button', { name: 'Open details for alice@example.com' }))
    expect(onSelect).toHaveBeenCalledWith(expect.objectContaining({ user_id: 'email|alice' }))
  })

  test('old snapshot without prev_cycle asks for a regenerate', () => {
    render(<LastMonth prev={undefined} users={users} cycle={cycle} enterpriseConsumed={900} onSelectUser={vi.fn()} />)
    expect(screen.getByText(/predates the Last Month page/)).toBeInTheDocument()
  })

  test('no previous cycle renders an explicit first-cycle state', () => {
    render(
      <LastMonth
        prev={{ available: false, reason: 'no_previous_cycle', cycle: null, enterprise: null, users: [] }}
        users={users}
        cycle={cycle}
        enterpriseConsumed={900}
        onSelectUser={vi.fn()}
      />,
    )
    expect(screen.getByText(/No previous billing cycle exists/)).toBeInTheDocument()
  })

  test('fetch failure renders the retry state', () => {
    render(
      <LastMonth
        prev={{ available: false, reason: 'fetch_failed', cycle: null, enterprise: null, users: [] }}
        users={users}
        cycle={cycle}
        enterpriseConsumed={900}
        onSelectUser={vi.fn()}
      />,
    )
    expect(screen.getByText(/unavailable \(fetch_failed\)/)).toBeInTheDocument()
  })
})
