import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { RefreshControls } from './RefreshControls'
import type { CycleInfo, RefreshInfo, RefreshStatusFile } from '../types'

const cycle: CycleInfo = {
  after: 1780272000,
  before: 1782864000,
  start_date: '2026-06-01',
  end_date: '2026-06-30',
  elapsed_days: 17,
  left_days: 13,
  cycle_days: 30,
}

const refresh: RefreshInfo = {
  enabled: true,
  interval_minutes: 5,
  interval_ms: 300000,
}

const countingDown: RefreshStatusFile = {
  state: 'counting_down',
  pct: 0,
  phase: '',
  detail: '',
  interval_seconds: 300,
  next_refresh_epoch: Math.floor(Date.now() / 1000) + 300,
  updated_at_epoch: Math.floor(Date.now() / 1000),
  generated_at: '2026-06-17T12:00:00Z',
}

describe('RefreshControls manual refresh feedback', () => {
  beforeEach(() => {
    vi.useRealTimers()
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  test('manual refresh hides the countdown button and shows refreshing feedback immediately', () => {
    render(
      <RefreshControls
        status={countingDown}
        stale={false}
        generatedAt="2026-06-17T12:00:00Z"
        cycle={cycle}
        refresh={refresh}
        manualRefreshing={true}
        onRefresh={vi.fn()}
      />,
    )

    expect(screen.queryByRole('button', { name: 'Refresh now' })).not.toBeInTheDocument()
    expect(screen.getByText('refreshing…')).toBeInTheDocument()
    expect(screen.getByText('Refreshing…')).toBeInTheDocument()
  })
})
