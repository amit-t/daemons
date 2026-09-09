import { describe, expect, it } from 'vitest'
import { orgCapTotals } from './orgCapTotals'
import type { OrgMeter, OrgRow } from './types'

function meter(limit: number | null): OrgMeter {
  return { consumed: 0, limit, daily_run_rate: 0, projected: 0, pct_limit: null, status: 'ok' }
}

function org(id: string, local: number | null, cloud: number | null): OrgRow {
  return {
    org_id: id,
    name: id,
    consumed: 0,
    daily_run_rate: 0,
    projected: 0,
    max_session_acu_limit: null,
    products: { devin: 0, cascade: 0, terminal: 0, review: 0 },
    local: meter(local),
    cloud: meter(cloud),
    status: 'ok',
  }
}

describe('orgCapTotals', () => {
  it('sums local + cloud gate limits across orgs', () => {
    const t = orgCapTotals([org('a', 100, 50), org('b', 25, null)])
    expect(t.limit_total).toBe(175)
    expect(t.capped_orgs).toBe(2)
    expect(t.uncapped_orgs).toBe(0)
  })

  it('counts an org with both gates null as uncapped', () => {
    const t = orgCapTotals([org('a', null, null), org('b', 0, null)])
    expect(t.limit_total).toBe(0)
    expect(t.capped_orgs).toBe(1) // zero cap is still a cap
    expect(t.uncapped_orgs).toBe(1)
  })

  it('handles empty roster', () => {
    expect(orgCapTotals([])).toEqual({ limit_total: 0, capped_orgs: 0, uncapped_orgs: 0 })
  })

  it('rounds fractional limits to 2 decimals', () => {
    const t = orgCapTotals([org('a', 10.005, 0.001)])
    expect(t.limit_total).toBe(10.01)
  })
})
