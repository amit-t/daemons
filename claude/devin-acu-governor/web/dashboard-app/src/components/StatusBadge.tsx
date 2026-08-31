export function StatusBadge({ status }: { status: string }) {
  return <span className={`badge badge-${status}`}>{status.replace('_', ' ')}</span>
}

// Cycle-end forecast badge, reusing the status palette: under → green,
// close → amber, over → the dashed forecast_over red.
const FORECAST_CLASS: Record<string, string> = {
  under: 'ok',
  close: 'warning',
  over: 'forecast_over',
}

export function ForecastBadge({ forecast }: { forecast?: 'under' | 'close' | 'over' | null }) {
  if (!forecast) return <>—</>
  return <span className={`badge badge-${FORECAST_CLASS[forecast]}`}>{forecast}</span>
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
