import { useMemo } from 'react'
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
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
}

interface Point extends DailyPoint {
  label: string
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

// Daily stacked product bars across the full cycle window, zero-filled for days
// without usage so the x-axis spans the whole cycle.
export function BurnChart({ daily, cycle }: Props) {
  const points = useMemo<Point[]>(() => {
    const byEpoch = new Map(daily.map((d) => [d.epoch, d]))
    const out: Point[] = []
    for (let i = 0; i < cycle.cycle_days; i++) {
      const epoch = cycle.after + i * 86400
      const d = byEpoch.get(epoch)
      const date = d?.date ?? new Date(epoch * 1000).toISOString().slice(0, 10)
      out.push({
        date,
        epoch,
        acus: d?.acus ?? 0,
        devin: d?.devin ?? 0,
        cascade: d?.cascade ?? 0,
        terminal: d?.terminal ?? 0,
        review: d?.review ?? 0,
        label: shortDay(date),
      })
    }
    return out
  }, [daily, cycle])

  return (
    <div>
      <ResponsiveContainer width="100%" height={280}>
        <BarChart data={points} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
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
          {Object.entries(PRODUCT_COLORS).map(([product, color]) => (
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
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}
