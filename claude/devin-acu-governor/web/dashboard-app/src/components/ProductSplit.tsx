import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from 'recharts'
import type { ProductSplit as Split } from '../types'
import { fmt } from '../format'

const COLORS: Record<string, string> = {
  devin: '#ffb224',
  cascade: '#60a5fa',
  terminal: '#2dd4bf',
  review: '#c084fc',
}

export function ProductSplitPanel({ split }: { split: Split[] }) {
  const total = split.reduce((s, p) => s + p.acus, 0)
  const data = split.filter((p) => p.acus > 0)
  return (
    <div>
      <ResponsiveContainer width="100%" height={170}>
        <PieChart>
          <Pie
            data={data.length ? data : [{ product: 'none', acus: 1 }]}
            dataKey="acus"
            nameKey="product"
            innerRadius={48}
            outerRadius={72}
            paddingAngle={2}
            stroke="#0e1311"
          >
            {(data.length ? data : [{ product: 'none', acus: 1 }]).map((p) => (
              <Cell key={p.product} fill={COLORS[p.product] ?? '#46584f'} />
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
          {split.map((p) => (
            <tr key={p.product}>
              <td>
                <span style={{ color: COLORS[p.product] ?? '#46584f' }}>●</span> {p.product}
              </td>
              <td className="num">{fmt(p.acus)}</td>
              <td className="num dim">{total > 0 ? ((p.acus / total) * 100).toFixed(1) + '%' : '—'}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
