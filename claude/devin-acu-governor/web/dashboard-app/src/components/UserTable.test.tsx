import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
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
  const user = userEvent.setup()
  Object.defineProperty(navigator, 'clipboard', {
    value: { writeText },
    configurable: true,
  })
  render(<UserTable users={[alice]} onSelect={onSelect} />)
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
