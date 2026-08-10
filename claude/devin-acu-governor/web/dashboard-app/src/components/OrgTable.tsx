import { useMemo, useState } from 'react'
import type { OrgMeter, OrgRow, OrgStatus } from '../types'
import { fmt, fmtPct } from '../format'
import { SortableTable, type Column } from './SortableTable'
import { Meter, StatusBadge } from './StatusBadge'

const STATUSES: OrgStatus[] = ['ok', 'warning', 'critical', 'forecast_over', 'over', 'blocked', 'uncapped']

// One enforcement gate rendered as "consumed / cap" plus a meter. The two
// gates (Local Agent, Devin Cloud) are independent — never one shared cap.
function GateCell({ meter }: { meter: OrgMeter }) {
  return (
    <>
      <span className="gate-figures">
        {fmt(meter.consumed)} / {meter.limit === null ? '—' : fmt(meter.limit)}
      </span>{' '}
      <Meter pct={meter.pct_limit} status={meter.status} />
      {fmtPct(meter.pct_limit)}
    </>
  )
}

function makeColumns(onSelect: (o: OrgRow) => void): Column<OrgRow>[] {
  return [
  { key: 'name', label: 'Org', sortValue: (o) => o.name.toLowerCase(), render: (o) => o.name },
  { key: 'consumed', label: 'Consumed', numeric: true, sortValue: (o) => o.consumed, render: (o) => fmt(o.consumed) },
  { key: 'rate', label: 'Rate/day', numeric: true, sortValue: (o) => o.daily_run_rate, render: (o) => fmt(o.daily_run_rate) },
  { key: 'projected', label: 'Projected', numeric: true, sortValue: (o) => o.projected, render: (o) => fmt(o.projected) },
  {
    key: 'local',
    label: 'Local Agent / cap',
    numeric: true,
    sortValue: (o) => o.local.pct_limit,
    render: (o) => <GateCell meter={o.local} />,
  },
  {
    key: 'cloud',
    label: 'Devin Cloud / cap',
    numeric: true,
    sortValue: (o) => o.cloud.pct_limit,
    render: (o) => <GateCell meter={o.cloud} />,
  },
  { key: 'session_cap', label: 'Session cap', numeric: true, sortValue: (o) => o.max_session_acu_limit, render: (o) => fmt(o.max_session_acu_limit) },
  { key: 'status', label: 'Status', sortValue: (o) => STATUSES.indexOf(o.status), render: (o) => <StatusBadge status={o.status} /> },
  {
    key: 'details',
    label: 'Details',
    render: (o) => (
      <button
        type="button"
        className="inline-action details-button"
        aria-label={`Open details for ${o.name}`}
        title="open org detail page"
        onClick={(e) => {
          e.stopPropagation()
          onSelect(o)
        }}
      >
        Details
      </button>
    ),
  },
  ]
}

export function OrgTable({ orgs, onSelect }: { orgs: OrgRow[]; onSelect: (o: OrgRow) => void }) {
  const [statusFilter, setStatusFilter] = useState<Set<OrgStatus>>(new Set())
  const columns = useMemo(() => makeColumns(onSelect), [onSelect])

  const present = useMemo(() => STATUSES.filter((s) => orgs.some((o) => o.status === s)), [orgs])
  const rows = useMemo(
    () => (statusFilter.size === 0 ? orgs : orgs.filter((o) => statusFilter.has(o.status))),
    [orgs, statusFilter],
  )

  function toggle(s: OrgStatus) {
    setStatusFilter((prev) => {
      const next = new Set(prev)
      if (next.has(s)) next.delete(s)
      else next.add(s)
      return next
    })
  }

  return (
    <section className="panel">
      <h2 className="panel-title">
        Organizations
        <span className="spacer" />
        <span className="controls">
          {present.map((s) => (
            <button key={s} className={`chip ${statusFilter.has(s) ? 'on' : ''}`} onClick={() => toggle(s)}>
              {s.replace('_', ' ')} ({orgs.filter((o) => o.status === s).length})
            </button>
          ))}
        </span>
      </h2>
      <SortableTable
        columns={columns}
        rows={rows}
        rowKey={(o) => o.org_id}
        initialSort={{ key: 'consumed', dir: 'desc' }}
      />
      <div className="row-count">
        {rows.length} of {orgs.length} orgs · use Details to open the per-org page
      </div>
    </section>
  )
}
