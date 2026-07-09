export function StatusBadge({ status }: { status: string }) {
  return <span className={`badge badge-${status}`}>{status.replace('_', ' ')}</span>
}

export function Meter({ pct, status }: { pct: number | null; status: string }) {
  if (pct === null) return null
  const cls =
    status === 'over' || status === 'forecast_over'
      ? 'over'
      : status === 'critical'
        ? 'critical'
        : status === 'warning'
          ? 'warning'
          : ''
  return (
    <span className={`meter ${cls}`.trim()}>
      <i style={{ width: `${Math.min(100, pct * 100)}%` }} />
    </span>
  )
}
