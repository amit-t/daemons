import { useMemo, useState } from 'react'
import type { CapSource, UserRow, UserStatus } from '../types'
import { fmt, fmtPct } from '../format'
import { SortableTable, type Column } from './SortableTable'
import { Meter, StatusBadge } from './StatusBadge'

const STATUSES: UserStatus[] = ['ok', 'warning', 'critical', 'over', 'blocked', 'uncapped']
const CAP_SOURCES: CapSource[] = ['explicit', 'default', 'uncapped']

const columns: Column<UserRow>[] = [
  { key: 'name', label: 'Name', sortValue: (u) => (u.name || '').toLowerCase(), render: (u) => u.name || '—' },
  { key: 'email', label: 'Email', sortValue: (u) => u.email.toLowerCase(), render: (u) => u.email || '—' },
  { key: 'consumed', label: 'Consumed', numeric: true, sortValue: (u) => u.consumed, render: (u) => fmt(u.consumed) },
  { key: 'cap', label: 'Effective cap', numeric: true, sortValue: (u) => u.effective_cycle_acu_limit, render: (u) => fmt(u.effective_cycle_acu_limit) },
  { key: 'headroom', label: 'Headroom', numeric: true, sortValue: (u) => u.headroom, render: (u) => fmt(u.headroom) },
  {
    key: 'pct',
    label: '% of cap',
    numeric: true,
    sortValue: (u) => u.pct_limit,
    render: (u) => (
      <>
        <Meter pct={u.pct_limit} status={u.status} />
        {fmtPct(u.pct_limit)}
      </>
    ),
  },
  { key: 'cap_source', label: 'Cap source', sortValue: (u) => u.cap_source, render: (u) => <span className="dim">{u.cap_source}</span> },
  { key: 'org', label: 'Billing org', sortValue: (u) => u.billing_org_id, render: (u) => <span className="dim">{u.billing_org_id ?? '—'}</span> },
  { key: 'status', label: 'Status', sortValue: (u) => STATUSES.indexOf(u.status), render: (u) => <StatusBadge status={u.status} /> },
]

export function UserTable({ users }: { users: UserRow[] }) {
  const [query, setQuery] = useState('')
  const [statusFilter, setStatusFilter] = useState<Set<UserStatus>>(new Set())
  const [sourceFilter, setSourceFilter] = useState<Set<CapSource>>(new Set())

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    return users.filter((u) => {
      if (statusFilter.size && !statusFilter.has(u.status)) return false
      if (sourceFilter.size && !sourceFilter.has(u.cap_source)) return false
      if (q && !u.email.toLowerCase().includes(q) && !(u.name || '').toLowerCase().includes(q) && !(u.billing_org_id || '').toLowerCase().includes(q))
        return false
      return true
    })
  }, [users, query, statusFilter, sourceFilter])

  function toggleIn<T>(set: Set<T>, v: T, apply: (s: Set<T>) => void) {
    const next = new Set(set)
    if (next.has(v)) next.delete(v)
    else next.add(v)
    apply(next)
  }

  return (
    <section className="panel">
      <h2 className="panel-title">
        User caps
        <span className="spacer" />
        <span className="controls">
          <input
            className="search"
            placeholder="filter by name / email / org…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </span>
      </h2>
      <div className="controls" style={{ marginBottom: 12 }}>
        {STATUSES.filter((s) => users.some((u) => u.status === s)).map((s) => (
          <button
            key={s}
            className={`chip ${statusFilter.has(s) ? 'on' : ''}`}
            onClick={() => toggleIn(statusFilter, s, setStatusFilter)}
          >
            {s} ({users.filter((u) => u.status === s).length})
          </button>
        ))}
        <span style={{ color: 'var(--text-faint)' }}>|</span>
        {CAP_SOURCES.filter((c) => users.some((u) => u.cap_source === c)).map((c) => (
          <button
            key={c}
            className={`chip ${sourceFilter.has(c) ? 'on' : ''}`}
            onClick={() => toggleIn(sourceFilter, c, setSourceFilter)}
          >
            cap: {c} ({users.filter((u) => u.cap_source === c).length})
          </button>
        ))}
      </div>
      <SortableTable
        columns={columns}
        rows={rows}
        rowKey={(u) => u.user_id}
        initialSort={{ key: 'consumed', dir: 'desc' }}
      />
      <div className="row-count">
        {rows.length} of {users.length} users · consumed {fmt(rows.reduce((s, u) => s + u.consumed, 0))} ACUs in view
      </div>
    </section>
  )
}
