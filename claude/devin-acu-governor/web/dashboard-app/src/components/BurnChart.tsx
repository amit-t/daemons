import { useMemo, useState } from 'react'
import {
  Area,
  Bar,
  CartesianGrid,
  ComposedChart,
  Legend,
  Line,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import type { CycleInfo, DailyPoint } from '../types'
import { fmt, shortDay } from '../format'

const PRODUCT_COLORS: Record<string, string> = {
  devin: '#ffb224',
  cascade: '#60a5fa',
  terminal: '#2dd4bf',
  review: '#c084fc',
}

interface Props {
  daily: DailyPoint[]
  cycle: CycleInfo
  pool: number
  runRate: number
  projected: number
}

interface Point extends DailyPoint {
  label: string
  cumulative: number | null
  forecast: number | null
}

function ChartTooltip({ active, payload, label }: { active?: boolean; payload?: Array<{ name?: string; value?: number | string; color?: string }>; label?: string }) {
  if (!active || !payload?.length) return null
  return (
    <div className="chart-tooltip">
      <div className="tt-date">{label}</div>
      {payload.map((p) => (
        <div className="tt-row" key={p.name}>
          <span style={{ color: p.color }}>{p.name}</span>
          <b>{fmt(typeof p.value === 'number' ? p.value : null)}</b>
        </div>
      ))}
    </div>
  )
}

// Daily stacked product bars + cumulative burn line + linear forecast to
// cycle end, with the monthly pool as a reference line.
export function BurnChart({ daily, cycle, pool, runRate, projected }: Props) {
  const [view, setView] = useState<'burn' | 'cumulative'>('burn')

  const points = useMemo<Point[]>(() => {
    const byEpoch = new Map(daily.map((d) => [d.epoch, d]))
    const out: Point[] = []
    let cum = 0
    const nowDays = cycle.elapsed_days
    for (let i = 0; i < cycle.cycle_days; i++) {
      const epoch = cycle.after + i * 86400
      const d = byEpoch.get(epoch)
      const date = d?.date ?? new Date(epoch * 1000).toISOString().slice(0, 10)
      const inPast = i < nowDays
      if (d) cum += d.acus
      out.push({
        date,
        epoch,
        acus: d?.acus ?? 0,
        devin: d?.devin ?? 0,
        cascade: d?.cascade ?? 0,
        terminal: d?.terminal ?? 0,
        review: d?.review ?? 0,
        label: shortDay(date),
        cumulative: inPast ? Math.round(cum * 100) / 100 : null,
        forecast: i >= nowDays - 1 ? Math.round(runRate * (i + 1) * 100) / 100 : null,
      })
    }
    return out
  }, [daily, cycle, runRate])

  const cumulative = view === 'cumulative'

  return (
    <div>
      <div className="controls" style={{ marginBottom: 10 }}>
        <button className={`chip ${view === 'burn' ? 'on' : ''}`} onClick={() => setView('burn')}>
          daily burn
        </button>
        <button
          className={`chip ${cumulative ? 'on' : ''}`}
          onClick={() => setView('cumulative')}
        >
          cumulative + forecast
        </button>
      </div>
      <ResponsiveContainer width="100%" height={280}>
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
            width={56}
          />
          <Tooltip content={<ChartTooltip />} cursor={{ fill: 'rgba(255,178,36,0.05)' }} />
          <Legend
            wrapperStyle={{ fontSize: 11, fontFamily: 'IBM Plex Mono', color: '#6f8479' }}
            iconSize={9}
          />
          {!cumulative &&
            Object.entries(PRODUCT_COLORS).map(([product, color]) => (
              <Bar
                key={product}
                dataKey={product}
                stackId="products"
                name={product}
                fill={color}
                fillOpacity={0.85}
                maxBarSize={26}
              />
            ))}
          {cumulative && (
            <>
              <Area
                dataKey="cumulative"
                name="consumed"
                stroke="#ffb224"
                strokeWidth={2}
                fill="rgba(255,178,36,0.12)"
                dot={false}
                connectNulls={false}
              />
              <Line
                dataKey="forecast"
                name={`forecast (${fmt(runRate)}/day → ${fmt(projected)})`}
                stroke="#f87171"
                strokeWidth={1.5}
                strokeDasharray="6 4"
                dot={false}
                connectNulls={false}
              />
              {pool <= Math.max(projected, pool) && (
                <ReferenceLine
                  y={pool}
                  stroke="#4ade80"
                  strokeDasharray="4 4"
                  label={{
                    value: `pool ${fmt(pool)}`,
                    fill: '#4ade80',
                    fontSize: 10,
                    fontFamily: 'IBM Plex Mono',
                    position: 'insideTopRight',
                  }}
                />
              )}
            </>
          )}
        </ComposedChart>
      </ResponsiveContainer>
    </div>
  )
}
