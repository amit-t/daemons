import { useCallback, useEffect, useRef, useState } from 'react'
import type { DashboardData, RefreshStatusFile } from './types'

// The live refresh channel (status.json) is tiny and local, so poll it often:
// it drives the countdown and the "Refreshing N%" progress, and advertises a
// fresh generated_at the moment the backend finishes rewriting data.json.
const STATUS_POLL_MS = 1000
const MANUAL_REFRESH_ENDPOINT = './__dag_refresh_now'
const MIN_MANUAL_REFRESH_FEEDBACK_MS = 750
const MAX_MANUAL_REFRESH_FEEDBACK_MS = 10_000

export interface DataState {
  data: DashboardData | null
  error: string | null
  lastRefreshed: Date | null
  stale: boolean
  status: RefreshStatusFile | null
  manualRefreshing: boolean
  refreshNow: () => void
}

function sameStatus(a: RefreshStatusFile | null, b: RefreshStatusFile | null): boolean {
  if (a === b) return true
  if (!a || !b) return false
  return (
    a.state === b.state &&
    a.pct === b.pct &&
    a.phase === b.phase &&
    a.detail === b.detail &&
    a.next_refresh_epoch === b.next_refresh_epoch &&
    a.generated_at === b.generated_at
  )
}

// Two channels, decoupled by cost: the heavy data.json snapshot (fetched on
// mount, on manual refresh, and whenever status.json advertises a newer
// generated_at) and the light status.json (polled every second to drive the
// countdown + progress without page reloads or UI flicker).
export function useDashboardData(): DataState {
  const [data, setData] = useState<DashboardData | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [lastRefreshed, setLastRefreshed] = useState<Date | null>(null)
  const [stale, setStale] = useState(false)
  const [status, setStatus] = useState<RefreshStatusFile | null>(null)
  const [manualRefreshing, setManualRefreshing] = useState(false)

  const generatedAt = useRef<string | null>(null)
  const hasData = useRef(false)
  const statusRef = useRef<RefreshStatusFile | null>(null)
  const mounted = useRef(true)
  const dataInFlight = useRef(false)
  const manualRefreshStartedAt = useRef(0)
  const manualRefreshTimer = useRef<number | null>(null)
  const manualRefreshMaxTimer = useRef<number | null>(null)

  const beginManualRefreshFeedback = useCallback(() => {
    manualRefreshStartedAt.current = performance.now()
    if (manualRefreshTimer.current !== null) {
      window.clearTimeout(manualRefreshTimer.current)
      manualRefreshTimer.current = null
    }
    if (manualRefreshMaxTimer.current !== null) {
      window.clearTimeout(manualRefreshMaxTimer.current)
      manualRefreshMaxTimer.current = null
    }
    setManualRefreshing(true)
  }, [])

  const endManualRefreshFeedback = useCallback(() => {
    const elapsed = performance.now() - manualRefreshStartedAt.current
    const delay = Math.max(0, MIN_MANUAL_REFRESH_FEEDBACK_MS - elapsed)
    if (manualRefreshTimer.current !== null) window.clearTimeout(manualRefreshTimer.current)
    if (manualRefreshMaxTimer.current !== null) {
      window.clearTimeout(manualRefreshMaxTimer.current)
      manualRefreshMaxTimer.current = null
    }
    manualRefreshTimer.current = window.setTimeout(() => {
      manualRefreshTimer.current = null
      if (mounted.current) setManualRefreshing(false)
    }, delay)
  }, [])

  const capManualRefreshFeedback = useCallback(() => {
    if (manualRefreshMaxTimer.current !== null) window.clearTimeout(manualRefreshMaxTimer.current)
    manualRefreshMaxTimer.current = window.setTimeout(() => {
      endManualRefreshFeedback()
    }, MAX_MANUAL_REFRESH_FEEDBACK_MS)
  }, [endManualRefreshFeedback])

  const fetchData = useCallback(async () => {
    if (dataInFlight.current) return
    dataInFlight.current = true
    try {
      const res = await fetch('./data.json', { cache: 'no-store' })
      if (!res.ok) throw new Error(`data.json HTTP ${res.status}`)
      const next = (await res.json()) as DashboardData
      if (!mounted.current) return
      generatedAt.current = next.generated_at
      hasData.current = true
      setData(next)
      setError(null)
      setStale(false)
      setLastRefreshed(new Date())
    } catch (e) {
      if (!mounted.current) return
      setError(e instanceof Error ? e.message : String(e))
      setStale(hasData.current)
    } finally {
      dataInFlight.current = false
    }
  }, [])

  // Manual refresh asks the local dashboard server to interrupt the backend
  // countdown and refetch data.json now. Older/static servers do not have that
  // endpoint, so fall back to re-pulling the latest already-written snapshot.
  const refreshNow = useCallback(() => {
    beginManualRefreshFeedback()
    void (async () => {
      let backendAccepted = false
      try {
        const res = await fetch(MANUAL_REFRESH_ENDPOINT, {
          method: 'POST',
          cache: 'no-store',
          headers: { 'X-DAG-Refresh': '1' },
        })
        if (!res.ok) {
          await fetchData()
        } else {
          backendAccepted = true
          capManualRefreshFeedback()
        }
      } catch {
        await fetchData()
      } finally {
        if (!backendAccepted) endManualRefreshFeedback()
      }
    })()
  }, [beginManualRefreshFeedback, capManualRefreshFeedback, endManualRefreshFeedback, fetchData])

  useEffect(() => {
    mounted.current = true
    let cancelled = false
    let timer: number | null = null

    async function pollStatus() {
      try {
        const res = await fetch('./status.json', { cache: 'no-store' })
        if (res.ok) {
          const s = (await res.json()) as RefreshStatusFile
          if (!cancelled && mounted.current) {
            // Dedup: only re-render when something the UI shows actually moved,
            // so the per-second poll does not thrash the chart subtree.
            if (!sameStatus(statusRef.current, s)) {
              statusRef.current = s
              setStatus(s)
            }
            if (s.state === 'refreshing') endManualRefreshFeedback()
            // A new snapshot is ready — pull the heavy data.json once.
            if (s.generated_at && s.generated_at !== generatedAt.current) {
              endManualRefreshFeedback()
              void fetchData()
            }
          }
        } else if (res.status === 404) {
          // No backend refresh loop (static snapshot) — clear any stale state.
          if (!cancelled && statusRef.current !== null) {
            statusRef.current = null
            setStatus(null)
          }
        }
      } catch {
        // status is best-effort; ignore transient read errors and keep polling.
      } finally {
        if (!cancelled) timer = window.setTimeout(pollStatus, STATUS_POLL_MS)
      }
    }

    void fetchData()
    void pollStatus()

    return () => {
      cancelled = true
      mounted.current = false
      if (manualRefreshTimer.current !== null) window.clearTimeout(manualRefreshTimer.current)
      if (manualRefreshMaxTimer.current !== null) window.clearTimeout(manualRefreshMaxTimer.current)
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [endManualRefreshFeedback, fetchData])

  return { data, error, lastRefreshed, stale, status, manualRefreshing, refreshNow }
}
