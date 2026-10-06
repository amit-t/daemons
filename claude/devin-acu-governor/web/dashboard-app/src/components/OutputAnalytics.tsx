import { useMemo } from 'react'
import type { OutputAnalyticsInfo, OutputDimension, OutputMember, OutputTotals, UserRow } from '../types'
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

function outputOf(member: OutputMember): OutputTotals | null {
  return member.output ?? null
}

function memberColumns(): Column<OutputMember>[] {
  return [
    { key: 'member', label: 'Member', sortValue: (member) => member.name || member.email, render: (member) => member.name || member.email || member.user_id },
    { key: 'inserted', label: 'Inserted', numeric: true, sortValue: (member) => total(outputOf(member), 'loc_inserted'), render: (member) => fmt(total(outputOf(member), 'loc_inserted')) },
    { key: 'deleted', label: 'Deleted', numeric: true, sortValue: (member) => total(outputOf(member), 'loc_deleted'), render: (member) => fmt(total(outputOf(member), 'loc_deleted')) },
    { key: 'net', label: 'Net', numeric: true, sortValue: (member) => total(outputOf(member), 'net'), render: (member) => fmt(total(outputOf(member), 'net')) },
    {
      key: 'desktop',
      label: 'Desktop',
      numeric: true,
      sortValue: (member) => member.output?.source_split.find((row) => row.source === 'CASCADE_CLIENT')?.net ?? null,
      render: (member) => fmt(member.output?.source_split.find((row) => row.source === 'CASCADE_CLIENT')?.net ?? null),
    },
    {
      key: 'cli',
      label: 'CLI',
      numeric: true,
      sortValue: (member) => member.output?.source_split.find((row) => row.source === 'CHISEL')?.net ?? null,
      render: (member) => fmt(member.output?.source_split.find((row) => row.source === 'CHISEL')?.net ?? null),
    },
  ]
}

function statusText(analytics: OutputAnalyticsInfo): string {
  if (analytics.state === 'no_data') return 'No accepted agent output was returned for this cycle.'
  if (analytics.reason === 'old_snapshot') return 'Unavailable: this snapshot predates agent output analytics; regenerate with dag dashboard.'
  if (analytics.reason === 'no_output_key') return 'Unavailable: no Windsurf or Devin service key with output analytics permission.'
  if (analytics.reason === 'auth_failed') return 'Unavailable: output analytics authentication or permission failed.'
  if (analytics.state === 'stale') return 'Stale: the last successful output snapshot is shown because the refresh failed.'
  if (analytics.reason) return `Unavailable: ${analytics.reason}.`
  return ''
}

export function OutputAnalytics({ analytics, users }: { analytics: OutputAnalyticsInfo; users: UserRow[] }) {
  const members = useMemo<OutputMember[]>(
    () =>
      analytics.members.length > 0
        ? analytics.members
        : users.map((user) => ({
            user_id: user.user_id,
            email: user.email,
            name: user.name,
            billing_org_id: user.billing_org_id,
            output: user.output ?? null,
          })),
    [analytics.members, users],
  )
  const columns = useMemo(() => memberColumns(), [])
  const status = statusText(analytics)

  return (
    <section id="agent-output" className="panel output-analytics" aria-label="Agent output analytics">
      <div className="output-heading">
        <h2 className="panel-title">Agent output</h2>
        {analytics.stale && <span className="badge badge-warning">stale</span>}
      </div>
      {status ? <div className="output-state">{status}</div> : null}
      <div className="output-freshness">
        <span>source data through {analytics.data_freshness ?? 'unknown'}</span>
        <span>snapshot fetched {analytics.fetched_at ?? 'unknown'}</span>
        {analytics.range_clamped && <span>API range limited to 90 days ({analytics.start_date} → {analytics.end_date})</span>}
      </div>
      {analytics.available && analytics.state !== 'no_data' && (
        <>
          <div className="output-cards">
            <div className="card accent">
              <div className="card-label">Accepted inserted</div>
              <div className="card-value">{fmt(total(analytics.totals, 'loc_inserted'))}</div>
            </div>
            <div className="card">
              <div className="card-label">Accepted deleted</div>
              <div className="card-value">{fmt(total(analytics.totals, 'loc_deleted'))}</div>
            </div>
            <div className="card">
              <div className="card-label">Accepted net</div>
              <div className="card-value">{fmt(total(analytics.totals, 'net'))}</div>
            </div>
          </div>
          <div className="output-grid">
            <section>
              <h3 className="subpanel-title">Source split</h3>
              <DimensionList rows={analytics.source_split} labelKey="source" />
            </section>
            <section>
              <h3 className="subpanel-title">Daily output</h3>
              <DailyList rows={analytics.daily} />
            </section>
            <section>
              <h3 className="subpanel-title">Model split</h3>
              <DimensionList rows={analytics.model_split} labelKey="model_uid" />
            </section>
            <section>
              <h3 className="subpanel-title">IDE split</h3>
              <DimensionList rows={analytics.ide_split} labelKey="ide" />
              <h3 className="subpanel-title output-subheading">OS split</h3>
              <DimensionList rows={analytics.os_split} labelKey="os" />
            </section>
          </div>
          <div className="output-attribution">
            <strong>Member-attributed estimates</strong>
            <span>
              {fmt(analytics.attribution?.matched.loc_inserted ?? 0)} inserted / {fmt(analytics.attribution?.matched.loc_deleted ?? 0)} deleted matched to current roster members.
            </span>
            <span>
              {fmt(analytics.attribution?.unassigned.loc_inserted ?? 0)} inserted / {fmt(analytics.attribution?.unassigned.loc_deleted ?? 0)} deleted from {analytics.attribution?.unmatched_contributors ?? 0} unmatched contributors; excluded from member and organization estimates.
            </span>
          </div>
          <h3 className="subpanel-title">Per-member accepted output</h3>
          <SortableTable columns={columns} rows={members} rowKey={(member) => member.user_id} initialSort={{ key: 'net', dir: 'desc' }} />
        </>
      )}
    </section>
  )
}
