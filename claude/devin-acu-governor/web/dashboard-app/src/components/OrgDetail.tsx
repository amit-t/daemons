import { useMemo, useState } from 'react'
import type {
  CloudSession,
  CloudSessionsInfo,
  CycleInfo,
  ModelAnalyticsInfo,
  OrgMeter,
  OrgRow,
  UserRow,
} from '../types'
import { fmt, fmtPct, fmtStamp, stampEpoch } from '../format'
import { BurnChart } from './BurnChart'
import { SortableTable, type Column } from './SortableTable'
import { Meter, StatusBadge } from './StatusBadge'
import { CopyEmail } from './CopyEmail'

const PRODUCT_COLORS: Record<string, string> = {
  devin: '#ffb224',
  cascade: '#60a5fa',
  terminal: '#2dd4bf',
  review: '#c084fc',
}

interface Props {
  org: OrgRow
  users: UserRow[]
  cycle: CycleInfo
  cloudSessions: CloudSessionsInfo | undefined
  modelAnalytics: ModelAnalyticsInfo
  onBack: () => void
  onSelectUser: (u: UserRow) => void
}

// Local Agent (Devin Desktop / Windsurf plugins / CLI — any model: GPT, Claude,
// …) usage for one member: cascade + terminal ACUs plus the message count
// Windsurf analytics saw.
function localAcus(u: UserRow): number {
  return u.product_totals.cascade + u.product_totals.terminal
}

function localMessages(u: UserRow): number {
  return u.models.reduce((s, m) => s + m.messages, 0)
}

// One enforcement gate as a card: consumed / cap, meter, projection.
function GateCard({ label, meter }: { label: string; meter: OrgMeter }) {
  const bad = meter.status === 'over' || meter.status === 'forecast_over'
  return (
    <div className={`card ${bad ? 'bad' : ''}`}>
      <div className="card-label">{label}</div>
      <div className={`card-value ${bad ? 'bad' : ''}`}>
        {fmt(meter.consumed)} / {meter.limit === null ? '∞' : fmt(meter.limit)}
      </div>
      <div className="card-sub">
        <Meter pct={meter.pct_limit} status={meter.status} />
        {meter.pct_limit !== null ? `${fmtPct(meter.pct_limit)} used · ` : ''}
        projected {fmt(meter.projected)}
      </div>
    </div>
  )
}

// Horizontal CSS bars: label, ACU bar scaled to the group max, value, messages.
// Same shape as the user drawer's list so the two views read alike.
function BarList({
  rows,
  emptyHint,
}: {
  rows: Array<{ label: string; tag?: string; acus: number; messages: number }>
  emptyHint: string
}) {
  if (rows.length === 0) return <div className="detail-empty">{emptyHint}</div>
  const max = Math.max(...rows.map((r) => r.acus), 0.0001)
  return (
    <div className="bar-list">
      {rows.map((r) => (
        <div className="bar-row" key={r.label}>
          <span className="bar-label" title={r.tag ? `${r.label} · top model: ${r.tag}` : r.label}>
            {r.label}
            {r.tag && <span className="bar-tag"> · {r.tag}</span>}
          </span>
          <span className="bar-track">
            <i style={{ width: `${Math.max(1, (r.acus / max) * 100)}%` }} />
          </span>
          <span className="bar-value">{fmt(r.acus)}</span>
          <span className="bar-msgs">{fmt(r.messages, 0)} msg</span>
        </div>
      ))}
    </div>
  )
}

// Who a session belongs to, best-effort: member email > service user > raw id.
function sessionOwner(s: CloudSession, byUserId: Map<string, UserRow>): string {
  if (s.user_id) {
    const u = byUserId.get(s.user_id)
    if (u) return u.email || u.name || s.user_id
    return s.user_id
  }
  if (s.service_user_id) return `${s.service_user_id} (service)`
  return '—'
}

function makeMemberColumns(onSelect: (u: UserRow) => void): Column<UserRow>[] {
  return [
    { key: 'name', label: 'Name', sortValue: (u) => (u.name || '').toLowerCase(), render: (u) => u.name || '—' },
    {
      key: 'email',
      label: 'Email',
      sortValue: (u) => u.email.toLowerCase(),
      render: (u) => (u.email ? <CopyEmail email={u.email} /> : '—'),
    },
    { key: 'consumed', label: 'Consumed', numeric: true, sortValue: (u) => u.consumed, render: (u) => fmt(u.consumed) },
    {
      key: 'local',
      label: 'Local Agent ACUs',
      numeric: true,
      sortValue: (u) => localAcus(u),
      render: (u) => fmt(localAcus(u)),
    },
    {
      key: 'cloud',
      label: 'Cloud ACUs',
      numeric: true,
      sortValue: (u) => u.product_totals.devin,
      render: (u) => fmt(u.product_totals.devin),
    },
    {
      key: 'sessions',
      label: 'Cloud sessions',
      numeric: true,
      sortValue: (u) => u.sessions?.count ?? null,
      render: (u) => (u.sessions ? fmt(u.sessions.count, 0) : '—'),
    },
    {
      key: 'session_acus',
      label: 'Session ACUs',
      numeric: true,
      sortValue: (u) => u.sessions?.acus ?? null,
      render: (u) => (u.sessions ? fmt(u.sessions.acus) : '—'),
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
    { key: 'status', label: 'Status', sortValue: (u) => u.status, render: (u) => <StatusBadge status={u.status} /> },
    {
      key: 'details',
      label: 'Details',
      render: (u) => (
        <button
          type="button"
          className="inline-action details-button"
          aria-label={`Open details for ${u.email || u.name || u.user_id}`}
          title="open user detail"
          onClick={(e) => {
            e.stopPropagation()
            onSelect(u)
          }}
        >
          Details
        </button>
      ),
    },
  ]
}

function makeSessionColumns(byUserId: Map<string, UserRow>): Column<CloudSession>[] {
  return [
    {
      key: 'created',
      label: 'Created',
      sortValue: (s) => stampEpoch(s.created_at),
      render: (s) => <span className="dim">{fmtStamp(s.created_at)}</span>,
    },
    {
      key: 'title',
      label: 'Session',
      sortValue: (s) => (s.title || s.session_id).toLowerCase(),
      render: (s) => (
        <span className="session-title" title={s.session_id}>
          {s.title || s.session_id}
          {s.url && (
            <>
              {' '}
              <a className="inline-action" href={s.url} target="_blank" rel="noreferrer">
                open
              </a>
            </>
          )}
        </span>
      ),
    },
    {
      key: 'owner',
      label: 'User',
      sortValue: (s) => sessionOwner(s, byUserId).toLowerCase(),
      render: (s) => sessionOwner(s, byUserId),
    },
    { key: 'origin', label: 'Origin', sortValue: (s) => s.origin, render: (s) => <span className="dim">{s.origin ?? '—'}</span> },
    {
      key: 'status',
      label: 'Status',
      sortValue: (s) => s.status,
      render: (s) => (
        <span className="dim">
          {s.status ?? '—'}
          {s.is_archived ? ' · archived' : ''}
        </span>
      ),
    },
    { key: 'acus', label: 'ACUs', numeric: true, sortValue: (s) => s.acus_consumed, render: (s) => fmt(s.acus_consumed) },
    {
      key: 'prs',
      label: 'PRs',
      numeric: true,
      sortValue: (s) => s.pull_requests.length,
      render: (s) => (s.pull_requests.length ? fmt(s.pull_requests.length, 0) : '—'),
    },
  ]
}

// Full-page org drill-down: the org's enforcement gates, daily burn, product
// split, its members' usage, and every Devin Cloud session it ran this cycle.
// Same console UX as the per-user drawer, promoted to a page (hash-routed).
export function OrgDetail({ org, users, cycle, cloudSessions, modelAnalytics, onBack, onSelectUser }: Props) {
  const [query, setQuery] = useState('')

  const members = useMemo(() => users.filter((u) => u.billing_org_id === org.org_id), [users, org.org_id])
  const byUserId = useMemo(() => new Map(members.map((u) => [u.user_id, u])), [members])

  // Local Agent activity: cascade + terminal ACUs per member, whatever model
  // they drive (GPT, Claude, …). The Devin API has no session list for Local
  // Agent, so activity is shown per member (tagged with their top model by
  // ACUs) and per model instead.
  const localMembers = useMemo(
    () =>
      members
        .filter((u) => localAcus(u) > 0)
        .sort((a, b) => localAcus(b) - localAcus(a))
        .map((u) => ({
          label: u.email || u.name || u.user_id,
          tag: u.models[0]?.model,
          acus: localAcus(u),
          messages: localMessages(u),
        })),
    [members],
  )
  const orgModels = useMemo(() => {
    const agg = new Map<string, { acus: number; messages: number }>()
    for (const u of members)
      for (const m of u.models) {
        const cur = agg.get(m.model) ?? { acus: 0, messages: 0 }
        cur.acus += m.acus
        cur.messages += m.messages
        agg.set(m.model, cur)
      }
    return [...agg.entries()]
      .map(([model, v]) => ({ label: model, acus: v.acus, messages: v.messages }))
      .sort((a, b) => b.acus - a.acus)
  }, [members])

  const orgSessions = useMemo(
    () => (cloudSessions?.items ?? []).filter((s) => s.org_id === org.org_id),
    [cloudSessions, org.org_id],
  )
  const sessionRows = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return orgSessions
    return orgSessions.filter(
      (s) =>
        (s.title || '').toLowerCase().includes(q) ||
        s.session_id.toLowerCase().includes(q) ||
        sessionOwner(s, byUserId).toLowerCase().includes(q) ||
        (s.status || '').toLowerCase().includes(q) ||
        (s.origin || '').toLowerCase().includes(q),
    )
  }, [orgSessions, query, byUserId])

  const memberColumns = useMemo(() => makeMemberColumns(onSelectUser), [onSelectUser])
  const sessionColumns = useMemo(() => makeSessionColumns(byUserId), [byUserId])

  const products = (['devin', 'cascade', 'terminal', 'review'] as const)
    .map((k) => ({ label: k, acus: org.products[k] }))
    .filter((p) => p.acus > 0)
  const productTotal = products.reduce((s, p) => s + p.acus, 0)

  const sessionAcus = orgSessions.reduce((s, x) => s + x.acus_consumed, 0)

  return (
    <div className="org-detail">
      <header className="detail-header">
        <div>
          <button type="button" className="inline-action page-back" onClick={onBack}>
            ← console
          </button>
          <h2 className="detail-name">{org.name}</h2>
          <div className="detail-sub">
            <span className="dim">{org.org_id}</span>
            <span className="dim">session cap: {fmt(org.max_session_acu_limit)}</span>
          </div>
        </div>
        <div className="detail-header-right">
          <StatusBadge status={org.status} />
        </div>
      </header>

      <div className="cards detail-cards">
        <div className="card accent">
          <div className="card-label">Cycle ACUs</div>
          <div className="card-value">{fmt(org.consumed)}</div>
          <div className="card-sub">
            {fmt(org.daily_run_rate)} / day · projected {fmt(org.projected)}
          </div>
        </div>
        <GateCard label="Local Agent / cap" meter={org.local} />
        <GateCard label="Devin Cloud / cap" meter={org.cloud} />
        <div className="card">
          <div className="card-label">Devin Cloud sessions</div>
          <div className="card-value">{org.sessions ? fmt(org.sessions.count, 0) : '—'}</div>
          <div className="card-sub">
            {org.sessions
              ? `${fmt(org.sessions.acus)} ACUs this cycle · cloud only — local usage in the Local Agent panels`
              : 'sessions API unavailable'}
          </div>
        </div>
      </div>

      {org.daily && org.daily.length > 0 ? (
        <section className="panel">
          <h2 className="panel-title">Daily burn</h2>
          <BurnChart daily={org.daily} cycle={cycle} />
        </section>
      ) : (
        <section className="panel">
          <h2 className="panel-title">Daily burn</h2>
          <div className="detail-empty">
            {org.daily ? 'no consumption this cycle' : 'not in this snapshot — regenerate with dag dashboard'}
          </div>
        </section>
      )}

      <div className="panel-grid">
        <section className="panel">
          <h2 className="panel-title">Product split</h2>
          {products.length === 0 ? (
            <div className="detail-empty">no consumption this cycle</div>
          ) : (
            <div className="bar-list">
              {products.map((p) => (
                <div className="bar-row" key={p.label}>
                  <span className="bar-label">
                    <span style={{ color: PRODUCT_COLORS[p.label] }}>●</span> {p.label}
                  </span>
                  <span className="bar-track">
                    <i style={{ width: `${(p.acus / productTotal) * 100}%`, background: PRODUCT_COLORS[p.label] }} />
                  </span>
                  <span className="bar-value">{fmt(p.acus)}</span>
                  <span className="bar-msgs">{((p.acus / productTotal) * 100).toFixed(1)}%</span>
                </div>
              ))}
            </div>
          )}
        </section>
        <section className="panel">
          <h2 className="panel-title">
            Local Agent models
            {modelAnalytics.stale && <span className="badge badge-warning">stale</span>}
          </h2>
          {modelAnalytics.available ? (
            <BarList rows={orgModels} emptyHint="no Local Agent activity among this org's members this cycle" />
          ) : (
            <div className="detail-empty">
              model split unavailable —{' '}
              {modelAnalytics.reason === 'no_windsurf_key'
                ? 'add a Windsurf service key (keychain: devin-service-key) to enable it'
                : 'Windsurf analytics fetch failed'}
            </div>
          )}
        </section>
      </div>

      <section className="panel">
        <h2 className="panel-title">Local Agent activity — per member, all models</h2>
        <BarList
          rows={localMembers}
          emptyHint="no Local Agent (cascade/terminal) ACUs among this org's members this cycle"
        />
        <div className="row-count">
          Local Agent sessions (Devin Desktop / Windsurf plugins / Devin CLI — GPT, Claude, whatever each engineer
          drives) have no session-list API; this is each member's cycle Local Agent burn, tagged with their top model
          by ACUs, with the message count Windsurf analytics saw. The session table below covers Devin Cloud only.
        </div>
      </section>

      <section className="panel">
        <h2 className="panel-title">Members</h2>
        {members.length === 0 ? (
          <div className="detail-empty">no member carries billing_org_id {org.org_id}</div>
        ) : (
          <>
            <SortableTable
              columns={memberColumns}
              rows={members}
              rowKey={(u) => u.user_id}
              initialSort={{ key: 'consumed', dir: 'desc' }}
            />
            <div className="row-count">
              {members.length} member{members.length === 1 ? '' : 's'} carry billing_org_id {org.org_id} · consumed{' '}
              {fmt(members.reduce((s, u) => s + u.consumed, 0))} ACUs · users without billing_org_id never appear here ·
              use Details to open the per-user drawer
            </div>
          </>
        )}
      </section>

      <section className="panel">
        <h2 className="panel-title">
          Devin Cloud sessions
          <span className="spacer" />
          <span className="controls">
            <input
              className="search"
              placeholder="filter by title / user / status / origin…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </span>
        </h2>
        {!cloudSessions ? (
          <div className="detail-empty">
            session list not in this snapshot — regenerate with <code>dag dashboard</code>
          </div>
        ) : !cloudSessions.available ? (
          <div className="detail-empty">sessions API unavailable when this snapshot was generated</div>
        ) : orgSessions.length === 0 ? (
          <div className="detail-empty">no Devin Cloud sessions created in this org this cycle</div>
        ) : (
          <>
            <SortableTable
              columns={sessionColumns}
              rows={sessionRows}
              rowKey={(s) => s.session_id}
              initialSort={{ key: 'created', dir: 'desc' }}
            />
            <div className="row-count">
              {sessionRows.length} of {orgSessions.length} sessions · {fmt(sessionAcus)} ACUs summed over the org's
              sessions this cycle
            </div>
          </>
        )}
      </section>
    </div>
  )
}
