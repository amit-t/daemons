import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from 'recharts'
import type { UserRow } from '../types'

// Headroom-remaining bands. A user lands in the first band where
// min < headroom <= max. Edges are trivially tweakable here; colors ramp
// red (out of headroom) -> green (lots left), a burn-down gradient.
const BANDS: Array<{ label: string; min: number; max: number; color: string }> = [
  { label: '0 / over-cap', min: -Infinity, max: 0, color: '#f87171' },
  { label: '1–25 left', min: 0, max: 25, color: '#fb923c' },
  { label: '25–100 left', min: 25, max: 100, color: '#ffb224' },
  { label: '100–500 left', min: 100, max: 500, color: '#60a5fa' },
  { label: '500+ left', min: 500, max: Infinity, color: '#4ade80' },
]

interface BandRow {
  label: string
  color: string
  count: number
}

export function UserSplitPanel({ users }: { users: UserRow[] }) {
  const uncapped = users.filter((u) => u.headroom === null).length
  const capped = users.filter((u) => u.headroom !== null)
  const cappedTotal = capped.length

  const rows: BandRow[] = BANDS.map((b) => ({
    label: b.label,
    color: b.color,
    count: capped.filter((u) => (u.headroom as number) > b.min && (u.headroom as number) <= b.max).length,
  }))

  const data = rows.filter((r) => r.count > 0)
  const pie = data.length ? data : [{ label: 'none', color: '#46584f', count: 1 }]

  return (
    <div>
      <ResponsiveContainer width="100%" height={170}>
        <PieChart>
          <Pie
            data={pie}
            dataKey="count"
            nameKey="label"
            innerRadius={48}
            outerRadius={72}
            paddingAngle={2}
            stroke="#0e1311"
          >
            {pie.map((r) => (
              <Cell key={r.label} fill={r.color} />
            ))}
          </Pie>
          <Tooltip
            formatter={(v: number | string, name: string) => [`${Number(v)} users`, name]}
            contentStyle={{
              background: '#111614',
              border: '1px solid #1f2a25',
              borderRadius: 5,
              fontSize: 11.5,
              fontFamily: 'IBM Plex Mono',
            }}
            itemStyle={{ color: '#cfe3d8' }}
          />
        </PieChart>
      </ResponsiveContainer>
      <table>
        <tbody>
          {rows.map((r) => (
            <tr key={r.label}>
              <td>
                <span style={{ color: r.color }}>●</span> {r.label}
              </td>
              <td className="num">{r.count}</td>
              <td className="num dim">
                {cappedTotal > 0 ? ((r.count / cappedTotal) * 100).toFixed(1) + '%' : '—'}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {uncapped > 0 && (
        <p className="dim" style={{ fontSize: 11, marginTop: 8 }}>
          {uncapped} uncapped (no cap)
        </p>
      )}
    </div>
  )
}
