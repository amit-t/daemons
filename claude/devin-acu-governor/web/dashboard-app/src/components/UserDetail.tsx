import { useEffect, useMemo } from 'react'
import {
  CartesianGrid,
  ComposedChart,
  Line,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import type { CycleInfo, ModelAnalyticsInfo, UserRow } from '../types'
import { fmt, fmtPct, shortDay } from '../format'
import { StatusBadge } from './StatusBadge'

const PRODUCT_COLORS: Record<string, string> = {
  devin: '#ffb224',
  cascade: '#60a5fa',
  terminal: '#2dd4bf',
  review: '#c084fc',
}

// Windsurf analytics `ide` values → display names.
const IDE_LABELS: Record<string, string> = {
  chisel: 'Devin Desktop',
  windsurf: 'Windsurf',
  jetbrains: 'JetBrains',
  cli: 'Devin CLI',
  web: 'Web',
}

interface Props {
  user: UserRow
  cycle: CycleInfo
  modelAnalytics: ModelAnalyticsInfo
  onClose: () => void
}

interface DayPoint {
  label: string
  date: string
  acus: number | null
  devin: number
  cascade: number
  terminal: number
  review: number
}

function DailyTooltip({ active, payload }: { active?: boolean; payload?: Array<{ payload?: DayPoint }> }) {
  const p = payload?.[0]?.payload
  if (!active || !p) return null
  return (
    <div className="chart-tooltip">
      <div className="tt-date">{p.date}</div>
      <div className="tt-row">
        <span>total</span>
        <b>{fmt(p.acus)}</b>
      </div>
      {(['devin', 'cascade', 'terminal', 'review'] as const)
        .filter((k) => p[k] > 0)
        .map((k) => (
          <div className="tt-row" key={k}>
            <span style={{ color: PRODUCT_COLORS[k] }}>{k}</span>
            <b>{fmt(p[k])}</b>
          </div>
        ))}
    </div>
  )
}

// Horizontal CSS bars: label, ACU bar scaled to the group max, value, messages.
function BarList({
  rows,
  emptyHint,
}: {
  rows: Array<{ label: string; acus: number; messages: number }>
  emptyHint: string
}) {
  if (rows.length === 0) return <div className="detail-empty">{emptyHint}</div>
  const max = Math.max(...rows.map((r) => r.acus), 0.0001)
  return (
    <div className="bar-list">
      {rows.map((r) => (
        <div className="bar-row" key={r.label}>
          <span className="bar-label" title={r.label}>
            {r.label}
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

// Per-user drill-down drawer: daily ACU line over the cycle, Devin Cloud
// session stats, and (when the Windsurf analytics key is configured) the
// model and IDE split for Devin Desktop / Local usage.
export function UserDetail({ user, cycle, modelAnalytics, onClose }: Props) {
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const points = useMemo<DayPoint[]>(() => {
    const byEpoch = new Map(user.daily.map((d) => [d.epoch, d]))
    const out: DayPoint[] = []
    for (let i = 0; i < cycle.cycle_days; i++) {
      const epoch = cycle.after + i * 86400
      const d = byEpoch.get(epoch)
      const date = d?.date ?? new Date(epoch * 1000).toISOString().slice(0, 10)
      out.push({
        label: shortDay(date),
        date,
        // Future days stay null so the line stops at "today".
        acus: i < cycle.elapsed_days ? (d?.acus ?? 0) : null,
        devin: d?.devin ?? 0,
        cascade: d?.cascade ?? 0,
        terminal: d?.terminal ?? 0,
        review: d?.review ?? 0,
      })
    }
    return out
  }, [user.daily, cycle])

  const products = (['devin', 'cascade', 'terminal', 'review'] as const)
    .map((k) => ({ label: k, acus: user.product_totals[k] }))
    .filter((p) => p.acus > 0)
  const productTotal = products.reduce((s, p) => s + p.acus, 0)

  const capText =
    user.effective_cycle_acu_limit === null
      ? '∞'
      : `${fmt(user.effective_cycle_acu_limit)} (${user.cap_source})`

  return (
    <div className="detail-overlay" onClick={onClose}>
      <aside className="detail-drawer" onClick={(e) => e.stopPropagation()}>
        <header className="detail-header">
          <div>
            <h2 className="detail-name">{user.name || user.email || user.user_id}</h2>
            <div className="detail-sub">
              {user.email && <span>{user.email}</span>}
              <span className="dim">{user.user_id}</span>
              {user.billing_org_id && <span className="dim">org: {user.billing_org_id}</span>}
            </div>
          </div>
          <div className="detail-header-right">
            <StatusBadge status={user.status} />
            <button className="detail-close" type="button" onClick={onClose} aria-label="close">
              ✕
            </button>
          </div>
        </header>

        <div className="cards detail-cards">
          <div className="card accent">
            <div className="card-label">Cycle ACUs</div>
            <div className="card-value">{fmt(user.consumed)}</div>
            <div className="card-sub">
              cap {capText}
              {user.pct_limit !== null ? ` · ${fmtPct(user.pct_limit)} used` : ''}
            </div>
          </div>
          <div className={`card ${user.headroom !== null && user.headroom < 0 ? 'bad' : ''}`}>
            <div className="card-label">Headroom</div>
            <div className={`card-value ${user.headroom !== null && user.headroom < 0 ? 'bad' : ''}`}>
              {fmt(user.headroom)}
            </div>
            <div className="card-sub">ACUs left under cap</div>
          </div>
          <div className="card">
            <div className="card-label">Devin Cloud sessions</div>
            <div className="card-value">{user.sessions ? fmt(user.sessions.count, 0) : '—'}</div>
            <div className="card-sub">
              {user.sessions ? `initiated this cycle` : 'sessions API unavailable'}
            </div>
          </div>
          <div className="card">
            <div className="card-label">Cloud session ACUs</div>
            <div className="card-value">{user.sessions ? fmt(user.sessions.acus) : '—'}</div>
            <div className="card-sub">summed over their sessions</div>
          </div>
        </div>

        <section className="panel detail-panel">
          <h2 className="panel-title">Daily ACU usage</h2>
          <ResponsiveContainer width="100%" height={200}>
            <ComposedChart data={points} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
              <CartesianGrid stroke="#1f2a25" strokeDasharray="3 3" vertical={false} />
              <XAxis
                dataKey="label"
                tick={{ fill: '#6f8479', fontSize: 10, fontFamily: 'IBM Plex Mono' }}
                tickLine={false}
                axisLine={{ stroke: '#1f2a25' }}
                interval="preserveStartEnd"
                minTickGap={28}
              />
              <YAxis
                tick={{ fill: '#6f8479', fontSize: 10, fontFamily: 'IBM Plex Mono' }}
                tickLine={false}
                axisLine={false}
                width={48}
              />
              <Tooltip content={<DailyTooltip />} cursor={{ stroke: 'rgba(255,178,36,0.25)' }} />
              {user.effective_cycle_acu_limit !== null &&
                user.effective_cycle_acu_limit > 0 &&
                cycle.cycle_days > 0 && (
                  <ReferenceLine
                    y={user.effective_cycle_acu_limit / cycle.cycle_days}
                    stroke="#46584f"
                    strokeDasharray="4 4"
                    label={{
                      value: 'cap pace',
                      fill: '#46584f',
                      fontSize: 9,
                      fontFamily: 'IBM Plex Mono',
                      position: 'insideTopRight',
                    }}
                  />
                )}
              <Line
                dataKey="acus"
                name="ACUs"
                stroke="#ffb224"
                strokeWidth={2}
                dot={false}
                connectNulls={false}
              />
            </ComposedChart>
          </ResponsiveContainer>
        </section>

        <div className="detail-grid">
          <section className="panel detail-panel">
            <h2 className="panel-title">
              Models
              {modelAnalytics.stale && <span className="badge badge-warning">stale</span>}
            </h2>
            {modelAnalytics.available ? (
              <BarList
                rows={user.models.map((m) => ({ label: m.model, acus: m.acus, messages: m.messages }))}
                emptyHint="no Devin Desktop / Local activity this cycle"
              />
            ) : (
              <div className="detail-empty">
                model split unavailable — {modelAnalytics.reason === 'no_windsurf_key'
                  ? 'add a Windsurf service key (keychain: devin-service-key) to enable it'
                  : 'Windsurf analytics fetch failed'}
              </div>
            )}
          </section>

          <section className="panel detail-panel">
            <h2 className="panel-title">Surfaces</h2>
            {modelAnalytics.available ? (
              <BarList
                rows={user.ides.map((i) => ({
                  label: IDE_LABELS[i.ide] ?? i.ide,
                  acus: i.acus,
                  messages: i.messages,
                }))}
                emptyHint="no Devin Desktop / Local activity this cycle"
              />
            ) : (
              <div className="detail-empty">unavailable without the Windsurf analytics key</div>
            )}
            <h2 className="panel-title" style={{ marginTop: 14 }}>
              Product split
            </h2>
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
                      <i
                        style={{
                          width: `${(p.acus / productTotal) * 100}%`,
                          background: PRODUCT_COLORS[p.label],
                        }}
                      />
                    </span>
                    <span className="bar-value">{fmt(p.acus)}</span>
                    <span className="bar-msgs">{((p.acus / productTotal) * 100).toFixed(1)}%</span>
                  </div>
                ))}
              </div>
            )}
          </section>
        </div>

        <footer className="detail-footer">
          {modelAnalytics.available && modelAnalytics.fetched_at && (
            <span>
              model/IDE analytics fetched {modelAnalytics.fetched_at}
              {modelAnalytics.start_date && ` (${modelAnalytics.start_date} → ${modelAnalytics.end_date})`}
            </span>
          )}
          <span>esc or click outside to close</span>
        </footer>
      </aside>
    </div>
  )
}
