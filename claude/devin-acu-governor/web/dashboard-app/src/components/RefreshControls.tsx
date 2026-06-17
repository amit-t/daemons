import { useEffect, useState } from 'react'
import type { CycleInfo, RefreshInfo, RefreshStatusFile } from '../types'
import { fmtDur, relTime } from '../format'

interface Props {
  status: RefreshStatusFile | null
  stale: boolean
  generatedAt: string
  cycle: CycleInfo
  refresh: RefreshInfo
  manualRefreshing?: boolean
  onRefresh: () => void
}

// The console-meta row, re-rendered once a second so the countdown ticks and
// the "x ago" label stays current — isolated here so the per-second tick never
// re-renders the charts. The countdown is derived locally from
// next_refresh_epoch; status.json only needs to be polled, not ticked.
export function RefreshControls({ status, stale, generatedAt, cycle, refresh, manualRefreshing = false, onRefresh }: Props) {
  const [, setTick] = useState(0)
  useEffect(() => {
    const id = window.setInterval(() => setTick((t) => t + 1), 1000)
    return () => window.clearInterval(id)
  }, [])

  const refreshing = status?.state === 'refreshing'
  const pct = Math.max(0, Math.min(100, Math.round(status?.pct ?? 0)))

  let countdown: number | null = null
  if (status?.state === 'counting_down' && status.next_refresh_epoch) {
    countdown = status.next_refresh_epoch - Math.floor(Date.now() / 1000)
  }
  // Bridge the ~1s gap between the countdown hitting zero and status.json
  // flipping to "refreshing": treat it as in-refresh so the button hides too.
  const inRefresh = manualRefreshing || refreshing || (countdown !== null && countdown <= 0)

  let dotClass = ''
  let statusText: string
  if (stale) {
    dotClass = 'stale'
    statusText = 'data stale — fetch failing'
  } else if (inRefresh) {
    dotClass = 'refreshing'
    statusText = refreshing
      ? `refreshing ${pct}%${status?.phase ? ` · ${status.phase}${status.detail ? ` (${status.detail})` : ''}` : ''}`
      : 'refreshing…'
  } else if (countdown !== null) {
    statusText = '' // rendered with markup below
  } else {
    statusText = `data refreshed ${relTime(generatedAt)}`
  }

  return (
    <div className="console-meta">
      <span>
        <span className={`live-dot ${dotClass}`} />
        {!stale && !inRefresh && countdown !== null ? (
          <>next refresh in <b>{fmtDur(countdown)}</b></>
        ) : (
          statusText
        )}
      </span>
      <span>
        cycle <b>{cycle.start_date} → {cycle.end_date}</b>
      </span>
      <span>
        day <b>{cycle.elapsed_days}/{cycle.cycle_days}</b> · {cycle.left_days} left
      </span>
      <span>
        {refresh.enabled ? `backend refresh every ${refresh.interval_minutes}m` : 'static snapshot'}
      </span>
      {inRefresh ? (
        <span className="refresh-progress" title={status?.phase ?? 'refreshing'}>
          <span className="refresh-progress-bar">
            <span className="refresh-progress-fill" style={{ width: `${pct}%` }} />
          </span>
          <span className="refresh-progress-label">{refreshing ? `Refreshing ${pct}%` : 'Refreshing…'}</span>
        </span>
      ) : (
        <button className="refresh-button" type="button" onClick={onRefresh}>
          Refresh now
        </button>
      )}
    </div>
  )
}
