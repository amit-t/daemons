import { useMemo, useState } from 'react'
import type { CycleInfo, PrevCycleInfo, UserRow } from '../types'
import { fmt, fmtPct } from '../format'
import { lastMonthRows, type LastMonthRow } from '../lastMonth'
import { SortableTable, type Column } from './SortableTable'

function Delta({ value, pct }: { value: number | null; pct: number | null }) {
  if (value === null) return <span className="dim">—</span>
  const cls = value > 0 ? 'delta-up' : value < 0 ? 'delta-down' : 'delta-flat'
  const sign = value > 0 ? '+' : ''
  return (
    <span className={cls}>
      {sign}
      {fmt(value)}
      {pct !== null ? ` (${sign}${fmtPct(pct)})` : ''}
    </span>
  )
}

function columns(onSelect: (row: LastMonthRow) => void): Column<LastMonthRow>[] {
  return [
    { key: 'member', label: 'Member', sortValue: (r) => r.name || r.email, render: (r) => r.name || r.email || r.user_id },
    { key: 'email', label: 'Email', sortValue: (r) => r.email, render: (r) => <span className="dim">{r.email}</span> },
    { key: 'last', label: 'Last month', numeric: true, sortValue: (r) => r.last_consumed, render: (r) => fmt(r.last_consumed) },
    { key: 'last_devin', label: 'LM Devin Cloud', numeric: true, sortValue: (r) => r.last_devin, render: (r) => fmt(r.last_devin) },
    { key: 'last_local', label: 'LM Local Agent', numeric: true, sortValue: (r) => r.last_local, render: (r) => fmt(r.last_local) },
    { key: 'current', label: 'This cycle', numeric: true, sortValue: (r) => r.current_consumed, render: (r) => fmt(r.current_consumed) },
    { key: 'projected', label: 'Projected', numeric: true, sortValue: (r) => r.projected, render: (r) => fmt(r.projected) },
    {
      key: 'delta',
      label: 'Δ projected vs last',
      numeric: true,
      sortValue: (r) => r.delta_projected,
      render: (r) => <Delta value={r.delta_projected} pct={r.pct_change} />,
    },
    {
      key: 'actions',
      label: '',
      render: (r) => (
        <button
          type="button"
          className="inline-action details-button"
          aria-label={`Open details for ${r.email || r.name || r.user_id}`}
          onClick={() => onSelect(r)}
        >
          Details
        </button>
      ),
    },
  ]
}

// Last Month page (#/last-month): every roster user's previous-cycle ACU usage
// next to this cycle's burn and projection. Previous cycle is immutable, so
// the backend fetches it once per cycle roll and caches it.
export function LastMonth({
  prev,
  users,
  cycle,
  enterpriseConsumed,
  onSelectUser,
}: {
  prev: PrevCycleInfo | undefined
  users: UserRow[]
  cycle: CycleInfo
  enterpriseConsumed: number
  onSelectUser: (user: UserRow) => void
}) {
  const [query, setQuery] = useState('')
  const rows = useMemo(() => (prev && prev.available ? lastMonthRows(users, prev) : []), [prev, users])
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return rows
    return rows.filter((r) => r.email.toLowerCase().includes(q) || r.name.toLowerCase().includes(q))
  }, [rows, query])
  const cols = useMemo(
    () =>
      columns((row) => {
        const user = users.find((u) => u.user_id === row.user_id)
        if (user) onSelectUser(user)
      }),
    [users, onSelectUser],
  )

  if (!prev) {
    return (
      <section className="panel" aria-label="Last month usage">
        <h2 className="panel-title">Last month</h2>
        <div className="output-state">This snapshot predates the Last Month page — regenerate with dag dashboard.</div>
      </section>
    )
  }
  if (!prev.available || !prev.cycle || !prev.enterprise) {
    const reason =
      prev.reason === 'no_previous_cycle'
        ? 'No previous billing cycle exists — this is the first cycle the API reports.'
        : `Previous-cycle data unavailable (${prev.reason ?? 'unknown'}); it will retry on the next refresh.`
    return (
      <section className="panel" aria-label="Last month usage">
        <h2 className="panel-title">Last month</h2>
        <div className="output-state">{reason}</div>
      </section>
    )
  }

  const deltaEnterprise = Math.round((enterpriseConsumed - prev.enterprise.consumed) * 100) / 100

  return (
    <section className="panel" aria-label="Last month usage">
      <h2 className="panel-title">
        Last month
        <span className="spacer" />
        <span className="panel-note">
          {prev.cycle.start_date} → {prev.cycle.end_date} · {prev.cycle.cycle_days} days
        </span>
      </h2>
      <div className="output-cards">
        <div className="card accent">
          <div className="card-label">Last month total</div>
          <div className="card-value">{fmt(prev.enterprise.consumed)}</div>
          <div className="card-sub">enterprise ACUs, full cycle</div>
        </div>
        <div className="card">
          <div className="card-label">This cycle so far</div>
          <div className="card-value">{fmt(enterpriseConsumed)}</div>
          <div className="card-sub">
            day {cycle.elapsed_days} of {cycle.cycle_days}
          </div>
        </div>
        <div className={`card ${deltaEnterprise > 0 ? 'bad' : 'good'}`}>
          <div className="card-label">Δ so far vs last month</div>
          <div className="card-value">
            {deltaEnterprise > 0 ? '+' : ''}
            {fmt(deltaEnterprise)}
          </div>
          <div className="card-sub">partial cycle vs finished cycle</div>
        </div>
      </div>
      <div className="controls lastmonth-controls">
        <input
          className="search"
          placeholder="search email / name…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search users"
        />
        <span className="row-count">
          {filtered.length} of {rows.length} users · Δ compares this cycle's run-rate projection against the finished previous cycle
        </span>
      </div>
      <SortableTable columns={cols} rows={filtered} rowKey={(r) => r.user_id} initialSort={{ key: 'last', dir: 'desc' }} />
    </section>
  )
}
