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
    expect(orgCapTotals([])).toEqual({
      limit_total: 0,
      capped_orgs: 0,
      uncapped_orgs: 0,
      parent_excluded: false,
    })
  })

  it('rounds fractional limits to 2 decimals', () => {
    const t = orgCapTotals([org('a', 10.005, 0.001)])
    expect(t.limit_total).toBe(10.01)
  })

  it('excludes the parent org from total and counts', () => {
    const t = orgCapTotals([org('vnt', 200, 0), org('a', 100, 0), org('b', 100, 0)], 'vnt')
    expect(t.limit_total).toBe(200)
    expect(t.capped_orgs).toBe(2)
    expect(t.uncapped_orgs).toBe(0)
    expect(t.parent_excluded).toBe(true)
  })

  it('ignores a parent id absent from the roster', () => {
    const t = orgCapTotals([org('a', 100, 0)], 'ghost')
    expect(t.limit_total).toBe(100)
    expect(t.parent_excluded).toBe(false)
  })

  it('does not exclude anything when parent id is null/undefined', () => {
    expect(orgCapTotals([org('a', 100, 0)], null).limit_total).toBe(100)
    expect(orgCapTotals([org('a', 100, 0)]).parent_excluded).toBe(false)
  })
})
