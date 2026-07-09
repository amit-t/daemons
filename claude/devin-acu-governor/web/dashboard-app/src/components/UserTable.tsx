import { useMemo, useState } from 'react'
import type { CapSource, UserRow, UserStatus } from '../types'
import { fmt, fmtPct } from '../format'
import { copyToClipboard } from '../clipboard'
import { SortableTable, type Column } from './SortableTable'
import { Meter, StatusBadge } from './StatusBadge'

const STATUSES: UserStatus[] = ['ok', 'warning', 'critical', 'over', 'blocked', 'uncapped']
const CAP_SOURCES: CapSource[] = ['explicit', 'default', 'uncapped']

// Email cell: static address plus explicit copy action. Copy never opens
// the detail drawer; only the Details button does that.
function EmailCell({ user }: { user: UserRow }) {
  if (!user.email) return <>—</>

  return (
    <span className="email-cell">
      <span className="email-text">{user.email}</span>
      <button
        type="button"
        className="inline-action copy-email-button"
        aria-label={`Copy ${user.email}`}
        title="copy email to clipboard"
        onClick={(e) => {
          e.stopPropagation()
          void copyToClipboard(user.email)
        }}
      >
        Copy
      </button>
    </span>
  )
}

function DetailsButton({ user, onSelect }: { user: UserRow; onSelect: (u: UserRow) => void }) {
  return (
    <button
      type="button"
      className="inline-action details-button"
      aria-label={`Open details for ${user.email || user.name || user.user_id}`}
      title="open user detail"
      onClick={(e) => {
        e.stopPropagation()
        onSelect(user)
      }}
    >
      Details
    </button>
  )
}

function makeColumns(onSelect: (u: UserRow) => void): Column<UserRow>[] {
  return [
    {
      key: 'name',
      label: 'Name',
      sortValue: (u) => (u.name || '').toLowerCase(),
      render: (u) => u.name || '—',
    },
    {
      key: 'email',
      label: 'Email',
      sortValue: (u) => u.email.toLowerCase(),
      render: (u) => <EmailCell user={u} />,
    },
    {
      key: 'consumed',
      label: 'Consumed',
      numeric: true,
      sortValue: (u) => u.consumed,
      render: (u) => fmt(u.consumed),
    },
    {
      key: 'cap',
      label: 'Effective cap',
      numeric: true,
      sortValue: (u) => u.effective_cycle_acu_limit,
      render: (u) => fmt(u.effective_cycle_acu_limit),
    },
    {
      key: 'headroom',
      label: 'Headroom',
      numeric: true,
      sortValue: (u) => u.headroom,
      render: (u) => fmt(u.headroom),
    },
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
    {
      key: 'status',
      label: 'Status',
      sortValue: (u) => STATUSES.indexOf(u.status),
      render: (u) => <StatusBadge status={u.status} />,
    },
    {
      key: 'cap_source',
      label: 'Cap source',
      sortValue: (u) => u.cap_source,
      render: (u) => <span className="dim">{u.cap_source}</span>,
    },
    {
      key: 'org',
      label: 'Billing org',
      sortValue: (u) => u.billing_org_id,
      render: (u) => <span className="dim">{u.billing_org_id ?? '—'}</span>,
    },
    {
      key: 'details',
      label: 'Details',
      render: (u) => <DetailsButton user={u} onSelect={onSelect} />,
    },
  ]
}

export function UserTable({ users, onSelect }: { users: UserRow[]; onSelect: (u: UserRow) => void }) {
  const [query, setQuery] = useState('')
  const [statusFilter, setStatusFilter] = useState<Set<UserStatus>>(new Set())
  const [sourceFilter, setSourceFilter] = useState<Set<CapSource>>(new Set())
  const columns = useMemo(() => makeColumns(onSelect), [onSelect])

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    return users.filter((u) => {
      if (statusFilter.size && !statusFilter.has(u.status)) return false
      if (sourceFilter.size && !sourceFilter.has(u.cap_source)) return false
      if (
        q &&
        !u.email.toLowerCase().includes(q) &&
        !(u.name || '').toLowerCase().includes(q) &&
        !(u.billing_org_id || '').toLowerCase().includes(q)
      )
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
        {rows.length} of {users.length} users · consumed {fmt(rows.reduce((s, u) => s + u.consumed, 0))} ACUs in view · use Copy beside an email to copy it · use Details to open the per-user drawer
      </div>
    </section>
  )
}
