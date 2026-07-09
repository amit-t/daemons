import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { useDashboardData } from './useDashboardData'
import type { DashboardData } from './types'

const sampleData = {
  generated_at: '2026-06-17T12:00:00Z',
  refresh: { enabled: true, interval_minutes: 5, interval_ms: 300000 },
  cycle: {
    after: 1780272000,
    before: 1782864000,
    start_date: '2026-06-01',
    end_date: '2026-06-30',
    elapsed_days: 17,
    left_days: 13,
    cycle_days: 30,
  },
  pool: 24000,
  enterprise: {},
  cap_totals: {},
  product_split: [],
  daily: [],
  sessions_info: {},
  model_analytics: {},
  orgs: [],
  users: [],
  warnings: [],
} as unknown as DashboardData

function okJson(body: unknown) {
  return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(body) } as Response)
}

function notFound() {
  return Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({}) } as Response)
}

function Harness() {
  const { data, error, manualRefreshing, refreshNow } = useDashboardData()
  return (
    <div>
      <div>{data ? 'loaded' : 'loading'}</div>
      <div>{error ?? 'no error'}</div>
      <div>{manualRefreshing ? 'manual refreshing' : 'idle'}</div>
      <button type="button" onClick={refreshNow}>Refresh now</button>
    </div>
  )
}

describe('useDashboardData manual refresh', () => {
  beforeEach(() => {
    vi.useRealTimers()
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('Refresh now requests a backend refresh and exposes immediate in-flight feedback', async () => {
    let finishRefreshRequest!: () => void
    const refreshRequest = new Promise<Response>((resolve) => {
      finishRefreshRequest = () => resolve({ ok: true, status: 202, json: () => Promise.resolve({ ok: true }) } as Response)
    })
    const fetchMock = vi.fn((input: RequestInfo | URL) => {
      const url = String(input)
      if (url === './data.json') return okJson(sampleData)
      if (url === './status.json') return notFound()
      if (url === './__dag_refresh_now') return refreshRequest
      return Promise.reject(new Error(`unexpected fetch ${url}`))
    })
    vi.stubGlobal('fetch', fetchMock)

    render(<Harness />)
    await screen.findByText('loaded')

    await userEvent.click(screen.getByRole('button', { name: 'Refresh now' }))

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        './__dag_refresh_now',
        expect.objectContaining({
          method: 'POST',
          cache: 'no-store',
          headers: expect.objectContaining({ 'X-DAG-Refresh': '1' }),
        }),
      )
    })
    expect(screen.getByText('manual refreshing')).toBeInTheDocument()

    finishRefreshRequest()
  })

  test('falls back to data.json without surfacing an endpoint error when manual endpoint is unsupported', async () => {
    let dataFetches = 0
    let finishFallbackFetch!: () => void
    const fallbackFetch = new Promise<Response>((resolve) => {
      finishFallbackFetch = () => resolve({ ok: true, status: 200, json: () => Promise.resolve(sampleData) } as Response)
    })
    const fetchMock = vi.fn((input: RequestInfo | URL) => {
      const url = String(input)
      if (url === './data.json') {
        dataFetches += 1
        return dataFetches === 1 ? okJson(sampleData) : fallbackFetch
      }
      if (url === './status.json') return notFound()
      if (url === './__dag_refresh_now') {
        return Promise.resolve({ ok: false, status: 501, json: () => Promise.resolve({}) } as Response)
      }
      return Promise.reject(new Error(`unexpected fetch ${url}`))
    })
    vi.stubGlobal('fetch', fetchMock)

    render(<Harness />)
    await screen.findByText('loaded')

    await userEvent.click(screen.getByRole('button', { name: 'Refresh now' }))

    await waitFor(() => expect(dataFetches).toBe(2))
    expect(screen.getByText('no error')).toBeInTheDocument()

    finishFallbackFetch()
  })
})
