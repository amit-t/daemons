import type { OrgRow } from './types'

export interface OrgCapTotals {
  // Σ over every org of (local gate limit + cloud gate limit); a null gate adds 0.
  limit_total: number
  capped_orgs: number
  uncapped_orgs: number
  // Σ org caps vs the ceiling (the monthly pool): null when no ceiling given.
  ceiling: number | null
  over_ceiling: boolean
  // ceiling - limit_total; negative when the org layer exceeds the ceiling.
  ceiling_headroom: number | null
}

// Org-level cap totals, computed client-side from the org rows so old
// data.json snapshots (whose cap_totals predates org totals) still render.
// Every org counts, the umbrella org included: consumption bills to exactly
// one org and each gate caps only its own org's usage, so Σ of all org caps
// is the real enterprise ceiling and must stay <= the monthly pool.
export function orgCapTotals(orgs: OrgRow[], ceiling?: number | null): OrgCapTotals {
  let limitTotal = 0
  let capped = 0
  for (const o of orgs) {
    const hasCap = o.local.limit != null || o.cloud.limit != null
    if (hasCap) capped += 1
    limitTotal += (o.local.limit ?? 0) + (o.cloud.limit ?? 0)
  }
  const total = Math.round(limitTotal * 100) / 100
  const hasCeiling = ceiling != null && ceiling > 0
  return {
    limit_total: total,
    capped_orgs: capped,
    uncapped_orgs: orgs.length - capped,
    ceiling: hasCeiling ? ceiling : null,
    over_ceiling: hasCeiling ? total > ceiling : false,
    ceiling_headroom: hasCeiling ? Math.round((ceiling - total) * 100) / 100 : null,
  }
}
