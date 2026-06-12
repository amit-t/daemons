import { useCallback, useEffect, useRef, useState } from 'react'
import type { DashboardData } from './types'

const FALLBACK_POLL_MS = 60_000

export type RefreshStatus = 'refreshing' | 'refreshed' | 'stale'

export interface DataState {
  data: DashboardData | null
  error: string | null
  lastChecked: Date | null
  lastRefreshed: Date | null
  refreshStatus: RefreshStatus
  refreshNow: () => void
  stale: boolean
}

type InternalDataState = Omit<DataState, 'refreshNow'>

// Background polling: silently refetch data.json (rewritten by the
// `dag dashboard --refresh` loop) and swap state only when the snapshot
// actually changed. No page reload, no UI flicker.
export function useDashboardData(): DataState {
  const [state, setState] = useState<InternalDataState>({
    data: null,
    error: null,
    lastChecked: null,
    lastRefreshed: null,
    refreshStatus: 'refreshing',
    stale: false,
  })
  const generatedAt = useRef<string | null>(null)
  const latestData = useRef<DashboardData | null>(null)
  const mounted = useRef(true)
  const inFlight = useRef(false)

  const poll = useCallback(async () => {
    if (inFlight.current) return
    inFlight.current = true
    if (mounted.current) {
      setState((prev) => ({ ...prev, refreshStatus: 'refreshing' }))
    }
    try {
      const res = await fetch('./data.json', { cache: 'no-store' })
      if (!res.ok) throw new Error(`data.json HTTP ${res.status}`)
      const next = (await res.json()) as DashboardData
      if (!mounted.current) return
      const changed = next.generated_at !== generatedAt.current
      generatedAt.current = next.generated_at
      const now = new Date()
      setState((prev) => {
        const data = changed || !prev.data ? next : prev.data
        latestData.current = data
        return {
          ...prev,
          data,
          error: null,
          lastChecked: now,
          lastRefreshed: now,
          refreshStatus: 'refreshed',
          stale: false,
        }
      })
    } catch (e) {
      if (!mounted.current) return
      setState((prev) => ({
        ...prev,
        error: e instanceof Error ? e.message : String(e),
        lastChecked: new Date(),
        refreshStatus: 'stale',
        stale: prev.data !== null,
      }))
    } finally {
      inFlight.current = false
    }
  }, [])

  const refreshNow = useCallback(() => {
    void poll()
  }, [poll])

  useEffect(() => {
    mounted.current = true
    let cancelled = false
    let timer: number | null = null

    async function loop() {
      await poll()
      if (cancelled) return
      const data = latestData.current
      const nextDelay = data?.refresh.enabled
        ? (data.refresh.interval_ms ?? FALLBACK_POLL_MS)
        : FALLBACK_POLL_MS
      timer = window.setTimeout(loop, nextDelay)
    }

    void loop()
    return () => {
      cancelled = true
      mounted.current = false
      if (timer !== null) window.clearTimeout(timer)
    }
  }, [poll])

  return { ...state, refreshNow }
}
