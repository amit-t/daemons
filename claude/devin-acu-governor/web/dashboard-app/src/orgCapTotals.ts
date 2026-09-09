import type { OrgRow } from './types'

export interface OrgCapTotals {
  // Σ over orgs of (local gate limit + cloud gate limit); a null gate adds 0.
  limit_total: number
  capped_orgs: number
  uncapped_orgs: number
}

// Org-level cap totals, computed client-side from the org rows so old
// data.json snapshots (whose cap_totals predates org totals) still render.
export function orgCapTotals(orgs: OrgRow[]): OrgCapTotals {
  let limitTotal = 0
  let capped = 0
  for (const o of orgs) {
    const hasCap = o.local.limit != null || o.cloud.limit != null
    if (hasCap) capped += 1
    limitTotal += (o.local.limit ?? 0) + (o.cloud.limit ?? 0)
  }
  return {
    limit_total: Math.round(limitTotal * 100) / 100,
    capped_orgs: capped,
    uncapped_orgs: orgs.length - capped,
  }
}
