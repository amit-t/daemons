import { useMemo, useState } from 'react'
import type { OutputAnalyticsInfo, OutputDimension, OutputMember, OutputTotals, PrevCycleInfo, UserRow } from '../types'
import type { OutputTab } from '../routes'
import { fmt } from '../format'
import { SortableTable, type Column } from './SortableTable'

const SOURCE_LABELS: Record<string, string> = {
  CASCADE_CLIENT: 'Desktop',
  CHISEL: 'CLI',
}

function sourceLabel(source: string): string {
  return SOURCE_LABELS[source] ?? source
}

function total(value: OutputTotals | null | undefined, key: keyof OutputTotals): number | null {
  return value ? value[key] : null
}

function DimensionList({ rows, labelKey }: { rows: OutputDimension[]; labelKey: 'source' | 'model_uid' | 'ide' | 'os' }) {
  if (rows.length === 0) return <div className="detail-empty">no dimension data returned</div>
  return (
    <div className="output-dimension-list">
      {rows.map((row) => (
        <div className="output-dimension-row" key={`${labelKey}-${row[labelKey]}`}>
          <span>{labelKey === 'source' ? sourceLabel(row[labelKey] ?? 'unknown') : row[labelKey] ?? 'unknown'}</span>
          <span className="num">{fmt(row.loc_inserted)} inserted</span>
          <span className="num">{fmt(row.loc_deleted)} deleted</span>
          <strong className="num">{fmt(row.net)} net</strong>
        </div>
      ))}
    </div>
  )
}

function DailyList({ rows }: { rows: OutputAnalyticsInfo['daily'] }) {
  if (rows.length === 0) return <div className="detail-empty">no daily output returned</div>
  const max = Math.max(...rows.map((row) => Math.max(row.loc_inserted, row.loc_deleted)), 1)
  return (
    <div className="output-daily-list">
      {rows.map((row) => (
        <div className="output-daily-row" key={row.date}>
          <span>{row.date}</span>
          <span className="output-daily-track">
            <i style={{ width: `${Math.max(1, (row.loc_inserted / max) * 100)}%` }} />
          </span>
          <span className="num">{fmt(row.loc_inserted)} / {fmt(row.loc_deleted)}</span>
          <strong className="num">{fmt(row.net)}</strong>
        </div>
      ))}
      <div className="output-daily-legend">
        <span>bar = inserted · deleted / net shown as text</span>
      </div>
    </div>
  )
}

function memberColumns(
  users: UserRow[],
  previous: boolean,
  prev: PrevCycleInfo | undefined,
  onSelectUser?: (user: UserRow) => void,
): Column<OutputMember>[] {
  const usageFor = (member: OutputMember) => {
    const user = users.find((candidate) => candidate.user_id === member.user_id)
    if (!previous) return user ? { total: user.consumed, agent: (user.product_totals?.cascade ?? 0) + (user.product_totals?.terminal ?? 0) } : null
    const usage = prev?.users.find((candidate) => candidate.user_id === member.user_id)
    return usage ? { total: usage.consumed, agent: usage.products.cascade + usage.products.terminal } : null
  }
  const outputFor = (member: OutputMember) => (member.output?.has_rows ? member.output : null)
  const sourceNet = (member: OutputMember, source: string) => outputFor(member)?.source_split.find((row) => row.source === source)?.net ?? 0
  const perAcu = (member: OutputMember) => {
    const output = outputFor(member)
    const usage = usageFor(member)
    return output && usage && usage.agent > 0 ? output.net / usage.agent : null
  }
  return [
    { key: 'member', label: 'Member', sortValue: (member) => member.name || member.email, render: (member) => member.name || member.email || member.user_id },
    { key: 'inserted', label: 'Inserted', numeric: true, sortValue: (member) => total(outputFor(member), 'loc_inserted'), render: (member) => fmt(total(outputFor(member), 'loc_inserted')) },
    { key: 'deleted', label: 'Deleted', numeric: true, sortValue: (member) => total(outputFor(member), 'loc_deleted'), render: (member) => fmt(total(outputFor(member), 'loc_deleted')) },
    { key: 'net', label: 'Net', numeric: true, sortValue: (member) => total(outputFor(member), 'net'), render: (member) => fmt(total(outputFor(member), 'net')) },
    { key: 'total-acus', label: 'ACUs total', numeric: true, sortValue: (member) => usageFor(member)?.total ?? null, render: (member) => fmt(usageFor(member)?.total) },
    { key: 'agent-acus', label: 'Agent ACUs', numeric: true, sortValue: (member) => usageFor(member)?.agent ?? null, render: (member) => fmt(usageFor(member)?.agent) },
    { key: 'per-acu', label: 'Net / agent ACU', numeric: true, sortValue: perAcu, render: (member) => fmt(perAcu(member)) },
    {
      key: 'surfaces',
      label: 'CLI / Desktop',
      numeric: true,
      sortValue: (member) => outputFor(member) ? sourceNet(member, 'CHISEL') : null,
      render: (member) => {
        const output = outputFor(member)
        return output ? `${fmt(sourceNet(member, 'CHISEL'))} / ${fmt(sourceNet(member, 'CASCADE_CLIENT'))}` : '—'
      },
    },
    {
      key: 'details',
      label: 'Details',
      render: (member) => {
        const user = users.find((candidate) => candidate.user_id === member.user_id)
        return (
          <button
            type="button"
            className="inline-action details-button"
            disabled={!user || !onSelectUser}
            aria-label={`Open details for ${member.name || member.email || member.user_id}`}
            onClick={() => user && onSelectUser?.(user)}
          >
            Details
          </button>
        )
      },
    },
  ]
}

function statusText(analytics: OutputAnalyticsInfo, previous: boolean): string {
  if (analytics.state === 'no_data') return previous ? 'No accepted agent output was returned for the previous billing cycle.' : 'No accepted agent output was returned for this cycle.'
  if (analytics.reason === 'old_snapshot') return 'Unavailable: this snapshot predates agent output analytics; regenerate with dag dashboard.'
  if (analytics.reason === 'no_output_key') return 'Unavailable: no Windsurf or Devin service key with output analytics permission.'
  if (analytics.reason === 'auth_failed') return 'Unavailable: output analytics authentication or permission failed.'
  if (analytics.state === 'stale') return 'Stale: the last successful output snapshot is shown because the refresh failed.'
  if (analytics.reason) return `Unavailable: ${analytics.reason}.`
  return ''
}

const OUTPUT_TABS: Array<{ tab: OutputTab; hash: string; label: string }> = [
  { tab: 'overview', hash: '#/output', label: 'Overview' },
  { tab: 'daily', hash: '#/output/daily', label: 'Daily' },
  { tab: 'splits', hash: '#/output/splits', label: 'Splits' },
  { tab: 'members', hash: '#/output/members', label: 'Members' },
]

// Agent output page (#/output/<tab>): team-scoped accepted-LoC analytics split
// into addressable sub-tab pages — Overview (totals, source split, attribution),
// Daily, Splits (model/IDE/OS), Members (per-member attributed estimates).
export function OutputAnalytics({
  analytics,
  previousAnalytics,
  prev,
  users,
  tab = 'overview',
  onSelectUser,
  period: controlledPeriod,
  onPeriodChange,
}: {
  analytics: OutputAnalyticsInfo
  previousAnalytics?: OutputAnalyticsInfo
  prev?: PrevCycleInfo
  users: UserRow[]
  tab?: OutputTab
  onSelectUser?: (user: UserRow) => void
  period?: 'current' | 'previous'
  onPeriodChange?: (period: 'current' | 'previous') => void
}) {
  const [localPeriod, setLocalPeriod] = useState<'current' | 'previous'>('current')
  const [query, setQuery] = useState('')
  const period = controlledPeriod ?? localPeriod
  const setPeriod = (next: 'current' | 'previous') => {
    setLocalPeriod(next)
    onPeriodChange?.(next)
  }
  const shown = period === 'previous' ? previousAnalytics : analytics
  const shownAnalytics = shown ?? {
    ...analytics,
    available: false,
    stale: false,
    state: 'unavailable' as const,
    reason: 'missing_previous_snapshot',
    totals: null,
    members: [],
  }
  const members = useMemo<OutputMember[]>(
    () =>
      shownAnalytics.available && shownAnalytics.members.length > 0
        ? shownAnalytics.members
        : shownAnalytics.available
          ? users.map((user) => ({
            user_id: user.user_id,
            email: user.email,
            name: user.name,
            billing_org_id: user.billing_org_id,
            output: period === 'previous' ? null : user.output ?? null,
          }))
          : [],
    [shownAnalytics, users],
  )
  const filteredMembers = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return members
    return members.filter((member) => `${member.name} ${member.email} ${member.user_id}`.toLowerCase().includes(q))
  }, [members, query])
  const columns = useMemo(() => memberColumns(users, period === 'previous', prev, onSelectUser), [users, period, prev, onSelectUser])
  const status = statusText(shownAnalytics, period === 'previous')
  const hasData = shownAnalytics.available && shownAnalytics.state !== 'no_data'

  return (
    <section id="agent-output" className="panel output-analytics" aria-label="Agent output analytics">
      <div className="output-heading">
        <h2 className="panel-title">Agent output</h2>
        {shownAnalytics.stale && <span className="badge badge-warning">stale</span>}
      </div>
      <div className="controls">
        <button type="button" className={`tab${period === 'current' ? ' on' : ''}`} onClick={() => setPeriod('current')}>
          Current cycle
        </button>
        <button type="button" className={`tab${period === 'previous' ? ' on' : ''}`} onClick={() => setPeriod('previous')}>
          Last month
        </button>
        {period === 'previous' && prev?.cycle ? (
          <span className="row-count">Previous billing cycle: {prev.cycle.start_date} → {prev.cycle.end_date}</span>
        ) : null}
      </div>
      <nav className="tab-bar" aria-label="Agent output pages">
        {OUTPUT_TABS.map((t) => (
          <a key={t.tab} href={t.hash} className={`tab${tab === t.tab ? ' on' : ''}`} aria-current={tab === t.tab ? 'page' : undefined}>
            {t.label}
          </a>
        ))}
      </nav>
      {status ? <div className="output-state">{status}</div> : null}
      <div className="output-freshness">
        <span>source data through {shownAnalytics.data_freshness ?? 'unknown'}</span>
        <span>snapshot fetched {shownAnalytics.fetched_at ?? 'unknown'}</span>
        {shownAnalytics.range_clamped && <span>API range limited to 90 days ({shownAnalytics.start_date} → {shownAnalytics.end_date})</span>}
      </div>
      {hasData && tab === 'overview' && (
        <>
          <div className="output-cards">
            <div className="card accent">
              <div className="card-label">Accepted inserted</div>
              <div className="card-value">{fmt(total(shownAnalytics.totals, 'loc_inserted'))}</div>
            </div>
            <div className="card">
              <div className="card-label">Accepted deleted</div>
              <div className="card-value">{fmt(total(shownAnalytics.totals, 'loc_deleted'))}</div>
            </div>
            <div className="card">
              <div className="card-label">Accepted net</div>
              <div className="card-value">{fmt(total(shownAnalytics.totals, 'net'))}</div>
            </div>
          </div>
          <h3 className="subpanel-title">Source split</h3>
          <DimensionList rows={shownAnalytics.source_split} labelKey="source" />
          <div className="output-attribution">
            <strong>Member-attributed estimates</strong>
            <span>
              {fmt(shownAnalytics.attribution?.matched.loc_inserted ?? 0)} inserted / {fmt(shownAnalytics.attribution?.matched.loc_deleted ?? 0)} deleted matched to current roster members.
            </span>
            <span>
              {fmt(shownAnalytics.attribution?.unassigned.loc_inserted ?? 0)} inserted / {fmt(shownAnalytics.attribution?.unassigned.loc_deleted ?? 0)} deleted from {shownAnalytics.attribution?.unmatched_contributors ?? 0} unmatched contributors; excluded from member and organization estimates.
            </span>
          </div>
        </>
      )}
      {hasData && tab === 'daily' && (
        <>
          <h3 className="subpanel-title">Daily output</h3>
          <DailyList rows={shownAnalytics.daily} />
        </>
      )}
      {hasData && tab === 'splits' && (
        <div className="output-grid">
          <section>
            <h3 className="subpanel-title">Source split</h3>
            <DimensionList rows={shownAnalytics.source_split} labelKey="source" />
          </section>
          <section>
            <h3 className="subpanel-title">Model split</h3>
            <DimensionList rows={shownAnalytics.model_split} labelKey="model_uid" />
          </section>
          <section>
            <h3 className="subpanel-title">IDE split</h3>
            <DimensionList rows={shownAnalytics.ide_split} labelKey="ide" />
          </section>
          <section>
            <h3 className="subpanel-title">OS split</h3>
            <DimensionList rows={shownAnalytics.os_split} labelKey="os" />
          </section>
        </div>
      )}
      {shownAnalytics.available && tab === 'members' && (
        <>
          <h3 className="subpanel-title">{period === 'previous' ? 'Previous billing-cycle member output' : 'Per-member accepted output'}</h3>
          <div className="controls">
            <input
              className="search"
              placeholder="search name / email / id…"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              aria-label="Search output members"
            />
            <span className="row-count">{filteredMembers.length} of {members.length} members</span>
          </div>
          {filteredMembers.length > 0 ? (
            <SortableTable columns={columns} rows={filteredMembers} rowKey={(member) => member.user_id} initialSort={{ key: 'per-acu', dir: 'desc' }} />
          ) : (
            <div className="detail-empty">No output members match the search.</div>
          )}
        </>
      )}
    </section>
  )
}
