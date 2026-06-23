import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from 'recharts'
import type { UserRow } from '../types'
import { fmt } from '../format'

// Slice color by user status, mirroring the .badge-<status> palette in app.css.
const STATUS_COLORS: Record<string, string> = {
  ok: '#4ade80',
  warning: '#ffb224',
  critical: '#fb923c',
  over: '#f87171',
  forecast_over: '#f87171',
  blocked: '#6f8479',
  uncapped: '#6f8479',
}

interface Slice {
  key: string
  label: string
  headroom: number
  status: string
}

export function UserSplitPanel({ users }: { users: UserRow[] }) {
  const rows: Slice[] = users.map((u) => ({
    key: u.user_id,
    label: u.name || u.email,
    headroom: u.headroom ?? 0,
    status: u.status,
  }))
  const total = rows.reduce((s, r) => s + Math.max(0, r.headroom), 0)
  const data = rows.filter((r) => r.headroom > 0)
  const pie = data.length ? data : [{ key: 'none', label: 'none', headroom: 1, status: 'blocked' }]
  return (
    <div>
      <ResponsiveContainer width="100%" height={170}>
        <PieChart>
          <Pie
            data={pie}
            dataKey="headroom"
            nameKey="label"
            innerRadius={48}
            outerRadius={72}
            paddingAngle={2}
            stroke="#0e1311"
          >
            {pie.map((r) => (
              <Cell key={r.key} fill={STATUS_COLORS[r.status] ?? '#46584f'} />
            ))}
          </Pie>
          <Tooltip
            formatter={(v: number | string, name: string) => [`${fmt(Number(v))} ACUs`, name]}
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
            <tr key={r.key}>
              <td>
                <span style={{ color: STATUS_COLORS[r.status] ?? '#46584f' }}>●</span> {r.label}
              </td>
              <td className="num">{fmt(r.headroom)}</td>
              <td className="num dim">{total > 0 ? ((Math.max(0, r.headroom) / total) * 100).toFixed(1) + '%' : '—'}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
