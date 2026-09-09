import type { OrgRow } from './types'

export interface OrgCapTotals {
  // Σ over non-parent orgs of (local gate limit + cloud gate limit); a null gate adds 0.
  limit_total: number
  capped_orgs: number
  uncapped_orgs: number
  // true when a parent org was found in the roster and left out of the totals.
  parent_excluded: boolean
}

// Org-level cap totals, computed client-side from the org rows so old
// data.json snapshots (whose cap_totals predates org totals) still render.
// The parent/umbrella org (data.parent_org_id) is excluded: its gates mirror
// the sum of every other org's caps, so counting it would double-count.
export function orgCapTotals(orgs: OrgRow[], parentOrgId?: string | null): OrgCapTotals {
  let limitTotal = 0
  let capped = 0
  let counted = 0
  let parentExcluded = false
  for (const o of orgs) {
    if (parentOrgId != null && o.org_id === parentOrgId) {
      parentExcluded = true
      continue
    }
    counted += 1
    const hasCap = o.local.limit != null || o.cloud.limit != null
    if (hasCap) capped += 1
    limitTotal += (o.local.limit ?? 0) + (o.cloud.limit ?? 0)
  }
  return {
    limit_total: Math.round(limitTotal * 100) / 100,
    capped_orgs: capped,
    uncapped_orgs: counted - capped,
    parent_excluded: parentExcluded,
  }
}
