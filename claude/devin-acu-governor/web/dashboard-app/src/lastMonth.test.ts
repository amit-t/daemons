import { describe, expect, test } from 'vitest'
import { lastMonthRows } from './lastMonth'
import type { PrevCycleInfo, UserRow } from './types'

const prev: PrevCycleInfo = {
  available: true,
  reason: null,
  cycle: { after: 1776326400, before: 1778918400, start_date: '2026-04-16', end_date: '2026-05-16', cycle_days: 30 },
  enterprise: { consumed: 1500, daily: [] },
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

describe('lastMonthRows', () => {
  test('joins previous-cycle usage by user_id and computes the projected delta', () => {
    const rows = lastMonthRows(
      [
        user({ user_id: 'email|alice', email: 'alice@example.com', name: 'Alice', consumed: 60, projected: 124 }),
        user({ user_id: 'email|bob', email: 'bob@example.com', name: 'Bob', consumed: 10, projected: 20 }),
      ],
      prev,
    )

    const alice = rows.find((r) => r.user_id === 'email|alice')!
    expect(alice.last_consumed).toBe(100)
    expect(alice.last_devin).toBe(30)
    expect(alice.last_local).toBe(70)
    expect(alice.current_consumed).toBe(60)
    expect(alice.delta_projected).toBe(24)
    expect(alice.pct_change).toBe(0.24)

    const bob = rows.find((r) => r.user_id === 'email|bob')!
    expect(bob.delta_projected).toBe(-20)
    expect(bob.pct_change).toBe(-0.5)
  })

  test('a roster user missing from the previous snapshot gets null last-month fields', () => {
    const rows = lastMonthRows([user({ user_id: 'email|new', consumed: 5, projected: 6 })], prev)
    expect(rows[0].last_consumed).toBeNull()
    expect(rows[0].last_devin).toBeNull()
    expect(rows[0].last_local).toBeNull()
    expect(rows[0].delta_projected).toBeNull()
    expect(rows[0].pct_change).toBeNull()
  })

  test('a user without a projection (pre-forecast snapshot) gets a null delta', () => {
    const rows = lastMonthRows([user({ user_id: 'email|alice', consumed: 60 })], prev)
    expect(rows[0].last_consumed).toBe(100)
    expect(rows[0].projected).toBeNull()
    expect(rows[0].delta_projected).toBeNull()
  })

  test('zero last-month usage yields a delta but no percentage', () => {
    const zeroPrev: PrevCycleInfo = {
      ...prev,
      users: [{ user_id: 'email|alice', consumed: 0, products: { devin: 0, cascade: 0, terminal: 0, review: 0 } }],
    }
    const rows = lastMonthRows([user({ user_id: 'email|alice', consumed: 10, projected: 12 })], zeroPrev)
    expect(rows[0].delta_projected).toBe(12)
    expect(rows[0].pct_change).toBeNull()
  })
})
