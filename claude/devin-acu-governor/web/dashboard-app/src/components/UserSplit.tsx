import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from 'recharts'
import type { UserRow } from '../types'
import { fmt } from '../format'

// Bands by % of cap remaining (pct = headroom / effective_cycle_acu_limit * 100),
// except the two bottom states which key off raw headroom. Ordered around the
// donut; colors ramp red (over cap) -> green (75-100% left). Edges are
// trivially tweakable in the matchers below.
interface BandDef {
  label: string
  color: string
  match: (m: { headroom: number; pct: number }) => boolean
}

const BANDS: BandDef[] = [
  { label: 'over cap', color: '#f87171', match: (m) => m.headroom < 0 },
  { label: 'maxed (0 left)', color: '#fba63c', match: (m) => m.headroom === 0 },
  { label: '<25% left', color: '#ffb224', match: (m) => m.pct > 0 && m.pct <= 25 },
  { label: '25–50% left', color: '#cddc39', match: (m) => m.pct > 25 && m.pct <= 50 },
  { label: '50–75% left', color: '#9ccc65', match: (m) => m.pct > 50 && m.pct <= 75 },
  { label: '75–100% left', color: '#4ade80', match: (m) => m.pct > 75 && m.pct <= 100 },
]

interface BandRow {
  label: string
  color: string
  count: number
  acus: number
}

export function UserSplitPanel({ users }: { users: UserRow[] }) {
  // Capped = finite cap > 0 and known headroom; everyone else is "uncapped".
  const capped = users.filter(
    (u) => u.headroom !== null && u.effective_cycle_acu_limit !== null && u.effective_cycle_acu_limit > 0,
  )
  const uncapped = users.length - capped.length
  const cappedTotal = capped.length

  const rows: BandRow[] = BANDS.map((b) => ({ label: b.label, color: b.color, count: 0, acus: 0 }))
  for (const u of capped) {
    const headroom = u.headroom as number
    const pct = (headroom / (u.effective_cycle_acu_limit as number)) * 100
    const i = BANDS.findIndex((b) => b.match({ headroom, pct }))
    if (i >= 0) {
      rows[i].count += 1
      rows[i].acus += u.consumed
    }
  }

  const data = rows.filter((r) => r.count > 0)
  const pie = data.length ? data : [{ label: 'none', color: '#46584f', count: 1, acus: 0 }]

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
        <thead>
          <tr>
            <th>band</th>
            <th className="num">users</th>
            <th className="num">ACUs used</th>
            <th className="num">% capped</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.label}>
              <td>
                <span style={{ color: r.color }}>●</span> {r.label}
              </td>
              <td className="num">{r.count}</td>
              <td className="num">{fmt(r.acus)}</td>
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
