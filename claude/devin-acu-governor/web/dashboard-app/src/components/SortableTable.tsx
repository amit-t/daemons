import { useMemo, useState, type ReactNode } from 'react'

export interface Column<T> {
  key: string
  label: string
  sortValue?: (row: T) => string | number | null
  render: (row: T) => ReactNode
  numeric?: boolean
}

interface Props<T> {
  columns: Column<T>[]
  rows: T[]
  rowKey: (row: T) => string
  initialSort: { key: string; dir: 'asc' | 'desc' }
}

// Null sort values always sink to the bottom regardless of direction —
// an uncapped user has no headroom, not the smallest headroom.
function compare(a: string | number | null, b: string | number | null): number {
  if (a === null && b === null) return 0
  if (a === null) return 1
  if (b === null) return -1
  if (typeof a === 'number' && typeof b === 'number') return a - b
  return String(a).localeCompare(String(b))
}

export function SortableTable<T>({ columns, rows, rowKey, initialSort }: Props<T>) {
  const [sort, setSort] = useState(initialSort)

  const sorted = useMemo(() => {
    const col = columns.find((c) => c.key === sort.key)
    if (!col?.sortValue) return rows
    const sv = col.sortValue
    const out = [...rows].sort((x, y) => compare(sv(x), sv(y)))
    if (sort.dir === 'desc') {
      // Reverse, but keep null sort values (already sunk) at the bottom.
      const nonNull = out.filter((r) => sv(r) !== null).reverse()
      const nulls = out.filter((r) => sv(r) === null)
      return [...nonNull, ...nulls]
    }
    return out
  }, [rows, columns, sort])

  function toggle(key: string, sortable: boolean) {
    if (!sortable) return
    setSort((prev) =>
      prev.key === key ? { key, dir: prev.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: 'desc' },
    )
  }

  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            {columns.map((c) => (
              <th
                key={c.key}
                className={[c.numeric ? 'num' : '', c.sortValue ? '' : 'no-sort'].join(' ').trim()}
                onClick={() => toggle(c.key, !!c.sortValue)}
              >
                {c.label}
                {sort.key === c.key && c.sortValue && (
                  <span className="arrow">{sort.dir === 'desc' ? '▾' : '▴'}</span>
                )}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {sorted.map((row) => (
            <tr key={rowKey(row)}>
              {columns.map((c) => (
                <td key={c.key} className={c.numeric ? 'num' : ''}>
                  {c.render(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
