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
      ceiling: null,
      over_ceiling: false,
      ceiling_headroom: null,
    })
  })

  it('rounds fractional limits to 2 decimals', () => {
    const t = orgCapTotals([org('a', 10.005, 0.001)])
    expect(t.limit_total).toBe(10.01)
  })

  it('counts the umbrella org like any other org (no hierarchy)', () => {
    const t = orgCapTotals([org('vnt', 200, 0), org('a', 100, 0), org('b', 100, 0)], 24000)
    expect(t.limit_total).toBe(400)
    expect(t.capped_orgs).toBe(3)
  })

  it('flags an org layer above the ceiling', () => {
    const t = orgCapTotals([org('vnt', 23998, 100), org('ics', 13608, 100), org('p', 10390, 0)], 24000)
    expect(t.limit_total).toBe(48196)
    expect(t.over_ceiling).toBe(true)
    expect(t.ceiling_headroom).toBe(-24196)
  })

  it('reports headroom under the ceiling', () => {
    const t = orgCapTotals([org('a', 20000, 0), org('b', 3000, 0)], 24000)
    expect(t.over_ceiling).toBe(false)
    expect(t.ceiling_headroom).toBe(1000)
  })

  it('has no ceiling verdict without a ceiling', () => {
    const t = orgCapTotals([org('a', 100, 0)])
    expect(t.ceiling).toBeNull()
    expect(t.over_ceiling).toBe(false)
    expect(t.ceiling_headroom).toBeNull()
  })
})
