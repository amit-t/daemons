import { useEffect, useRef, useState } from 'react'
import type { DashboardData } from './types'

const POLL_MS = 60_000

export interface DataState {
  data: DashboardData | null
  error: string | null
  lastChecked: Date | null
  stale: boolean
}

// Background polling: silently refetch data.json (rewritten by the
// `dag dashboard --refresh` loop) and swap state only when the snapshot
// actually changed. No page reload, no UI flicker.
export function useDashboardData(): DataState {
  const [state, setState] = useState<DataState>({
    data: null,
    error: null,
    lastChecked: null,
    stale: false,
  })
  const generatedAt = useRef<string | null>(null)

  useEffect(() => {
    let cancelled = false

    async function poll() {
      try {
        const res = await fetch('./data.json', { cache: 'no-store' })
        if (!res.ok) throw new Error(`data.json HTTP ${res.status}`)
        const next = (await res.json()) as DashboardData
        if (cancelled) return
        const changed = next.generated_at !== generatedAt.current
        generatedAt.current = next.generated_at
        setState((prev) => ({
          data: changed || !prev.data ? next : prev.data,
          error: null,
          lastChecked: new Date(),
          stale: false,
        }))
      } catch (e) {
        if (cancelled) return
        setState((prev) => ({
          ...prev,
          error: e instanceof Error ? e.message : String(e),
          lastChecked: new Date(),
          stale: prev.data !== null,
        }))
      }
    }

    poll()
    const id = window.setInterval(poll, POLL_MS)
    return () => {
      cancelled = true
      window.clearInterval(id)
    }
  }, [])

  return state
}
