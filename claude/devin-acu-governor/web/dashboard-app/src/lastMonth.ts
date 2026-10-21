import type { PrevCycleInfo, UserRow } from './types'

// One Last Month comparison row: the previous (finished) cycle's consumption
// joined by user_id against the current roster row. last_* fields are null for
// a roster user missing from the prev-cycle snapshot (joined after the cache
// was built and before the backend refetched); the UI renders '—'.
export interface LastMonthRow {
  user_id: string
  email: string
  name: string
  last_consumed: number | null
  last_devin: number | null
  last_local: number | null
  current_consumed: number
  projected: number | null
  delta_projected: number | null
  pct_change: number | null
}

export function lastMonthRows(users: UserRow[], prev: PrevCycleInfo): LastMonthRow[] {
  const byId = new Map(prev.users.map((u) => [u.user_id, u]))
  return users.map((user) => {
    const p = byId.get(user.user_id) ?? null
    const last = p ? p.consumed : null
    const projected = user.projected ?? null
    // Δ compares like with like: the full previous cycle vs this cycle's
    // run-rate projection, not vs a partial cycle's raw consumption.
    const delta = last != null && projected != null ? Math.round((projected - last) * 100) / 100 : null
    return {
      user_id: user.user_id,
      email: user.email,
      name: user.name,
      last_consumed: last,
      last_devin: p ? p.products.devin : null,
      last_local: p ? Math.round((p.products.cascade + p.products.terminal) * 100) / 100 : null,
      current_consumed: user.consumed,
      projected,
      delta_projected: delta,
      pct_change: delta != null && last != null && last > 0 ? Math.round((delta / last) * 1000) / 1000 : null,
    }
  })
}
