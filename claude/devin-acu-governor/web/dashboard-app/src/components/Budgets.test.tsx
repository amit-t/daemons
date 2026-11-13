import { afterEach, describe, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import { Budgets } from './Budgets'
import type { Budget, OrgRow } from '../types'

const parent: Budget = {
  budget_id: 'account',
  name: 'Account',
  parent_budget_id: null,
  org_ids: ['org-a'],
  status: 'active',
  cycle_acu_limit: 100,
  temporary_cycle_acu_limit: null,
}
const child: Budget = {
  budget_id: 'child',
  name: 'Child',
  parent_budget_id: 'account',
  org_ids: ['org-a'],
  status: 'active',
  cycle_acu_limit: 50,
  temporary_cycle_acu_limit: null,
}
const sibling: Budget = { ...child, budget_id: 'sibling', name: 'Sibling', cycle_acu_limit: 20, org_ids: ['org-b'] }
const orgs = [
  { org_id: 'org-a', name: 'Alpha', consumed: 20, projected: 40 },
  { org_id: 'org-b', name: 'Beta', consumed: 10, projected: 20 },
] as OrgRow[]

function renderBudgets(selectedId?: string) {
  return render(
    <Budgets budgets={[parent, child, sibling]} orgs={orgs} selectedId={selectedId} onBudgets={vi.fn()} refreshNow={vi.fn()} />,
  )
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('budget dashboard', () => {
  test('loads live budgets and renders account tree plus searchable table', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))))
    const { container } = renderBudgets()
    expect(screen.getByText('Account tree')).toBeInTheDocument()
    expect(container.querySelector('.budget-tree-root > .budget-tree-node > .budget-children')?.children.length).toBe(2)
    expect(screen.getAllByText('Account').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Child').length).toBeGreaterThan(0)
    fireEvent.change(screen.getByLabelText('Search budgets'), { target: { value: 'Sibling' } })
    expect(screen.getAllByText('Sibling').length).toBeGreaterThan(0)
    expect(screen.queryByText('Child', { selector: 'td' })).not.toBeInTheDocument()
  })

  test('shows a parent allocation warning before save and requires acknowledgement', async () => {
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({ tiers: [], requests: [], availability: { tiers: true, requests: true } })))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))
    }))
    renderBudgets('child')
    await screen.findByText('Edit limits')
    fireEvent.click(screen.getByRole('button', { name: 'Edit limits' }))
    fireEvent.change(screen.getByLabelText('Monthly limit'), { target: { value: '200' } })
    expect(screen.getByText('Parent allocation warning')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save limits' })).toBeDisabled()
    fireEvent.click(screen.getByLabelText(/I understand/))
    expect(screen.getByRole('button', { name: 'Save limits' })).not.toBeDisabled()
  })

  test('surfaces a stale 409, closes the editor, and refetches live budgets', async () => {
    const onBudgets = vi.fn()
    const refreshNow = vi.fn()
    let update = true
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({ tiers: [], requests: [], availability: { tiers: true, requests: true } })))
      if (String(input) === '/__dag_budget_update') {
        return update
          ? Promise.resolve(new Response(JSON.stringify({ error: 'budget changed since it was loaded' }), { status: 409 }))
          : Promise.resolve(new Response(JSON.stringify({ ok: true, budget: { ...child, cycle_acu_limit: 70 } }), { status: 200 }))
      }
      return Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))
    }))
    render(<Budgets budgets={[parent, child, sibling]} orgs={orgs} selectedId="child" onBudgets={onBudgets} refreshNow={refreshNow} />)
    await screen.findByText('Edit limits')
    fireEvent.click(screen.getByRole('button', { name: 'Edit limits' }))
    fireEvent.change(screen.getByLabelText('Monthly limit'), { target: { value: '70' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save limits' }))
    await waitFor(() => expect(screen.getByText(/Budget changed on the server/)).toBeInTheDocument())
    expect(screen.queryByRole('button', { name: 'Save limits' })).not.toBeInTheDocument()
    expect(onBudgets).toHaveBeenCalled()
    expect(update).toBe(true)
  })

  test('applies a verified successful mutation and refreshes the snapshot', async () => {
    const onBudgets = vi.fn()
    const refreshNow = vi.fn()
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({ tiers: [], requests: [], availability: { tiers: true, requests: true } })))
      if (String(input) === '/__dag_budget_update') return Promise.resolve(new Response(JSON.stringify({ ok: true, budget: { ...child, cycle_acu_limit: 70 } }), { status: 200 }))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))
    }))
    render(<Budgets budgets={[parent, child, sibling]} orgs={orgs} selectedId="child" onBudgets={onBudgets} refreshNow={refreshNow} />)
    await screen.findByText('Edit limits')
    fireEvent.click(screen.getByRole('button', { name: 'Edit limits' }))
    fireEvent.change(screen.getByLabelText('Monthly limit'), { target: { value: '70' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save limits' }))
    await waitFor(() => expect(onBudgets).toHaveBeenCalled())
    expect(refreshNow).toHaveBeenCalled()
  })

  test('marks partial success ambiguous and forces a live re-fetch', async () => {
    const onBudgets = vi.fn()
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({ tiers: [], requests: [], availability: { tiers: true, requests: true } })))
      if (String(input) === '/__dag_budget_update') return Promise.resolve(new Response(JSON.stringify({ partial_success: true, error: 'verification failed' }), { status: 502 }))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))
    }))
    render(<Budgets budgets={[parent, child, sibling]} orgs={orgs} selectedId="child" onBudgets={onBudgets} refreshNow={vi.fn()} />)
    await screen.findByText('Edit limits')
    fireEvent.click(screen.getByRole('button', { name: 'Edit limits' }))
    fireEvent.change(screen.getByLabelText('Monthly limit'), { target: { value: '70' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save limits' }))
    await waitFor(() => expect(screen.getByText(/AMBIGUOUS RESULT/)).toBeInTheDocument())
    expect(screen.queryByRole('button', { name: 'Save limits' })).not.toBeInTheDocument()
    expect(onBudgets).toHaveBeenCalled()
  })

  test('disables no-op and invalid inputs and resets warning acknowledgement', async () => {
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({ tiers: [], requests: [], availability: { tiers: true, requests: true } })))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))
    }))
    renderBudgets('child')
    await screen.findByText('Edit limits')
    fireEvent.click(screen.getByRole('button', { name: 'Edit limits' }))
    expect(screen.getByRole('button', { name: 'Save limits' })).toBeDisabled()
    fireEvent.change(screen.getByLabelText('Monthly limit'), { target: { value: ' ' } })
    expect(screen.getByText('Limits must be empty or nonnegative integer text.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save limits' })).toBeDisabled()
    fireEvent.change(screen.getByLabelText('Monthly limit'), { target: { value: '200' } })
    fireEvent.click(screen.getByLabelText(/I understand/))
    expect(screen.getByRole('button', { name: 'Save limits' })).not.toBeDisabled()
    fireEvent.change(screen.getByLabelText('Monthly limit'), { target: { value: '70' } })
    expect(screen.queryByLabelText(/I understand/)).not.toBeInTheDocument()
  })

  test('shows snapshot consumed and projected warnings for a lower proposed limit', async () => {
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({ tiers: [], requests: [], availability: { tiers: true, requests: true } })))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))
    }))
    renderBudgets('child')
    await screen.findByText('Edit limits')
    fireEvent.click(screen.getByRole('button', { name: 'Edit limits' }))
    fireEvent.change(screen.getByLabelText('Monthly limit'), { target: { value: '10' } })
    expect(screen.getByText(/below snapshot consumed 20/)).toBeInTheDocument()
    expect(screen.getByText(/below snapshot projected 40/)).toBeInTheDocument()
  })

  test('shows archived and missing-budget states', async () => {
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({ tiers: [], requests: [], availability: { tiers: true, requests: true } })))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent] }), { status: 200 }))
    }))
    render(<Budgets budgets={[{ ...parent, status: 'archived' }]} orgs={orgs} selectedId="account" onBudgets={vi.fn()} refreshNow={vi.fn()} />)
    await screen.findByText('Edit limits')
    expect(screen.getByRole('button', { name: 'Edit limits' })).toBeDisabled()
    cleanup()
    render(<Budgets budgets={[parent]} orgs={orgs} selectedId="missing" onBudgets={vi.fn()} refreshNow={vi.fn()} />)
    expect(await screen.findByText(/was not found in the live budget response/)).toBeInTheDocument()
  })

  test('labels missing tiers and pending requests as unavailable', async () => {
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({
        tiers: [], requests: [], availability: { tiers: false, requests: false },
        tiers_error: 'tiers endpoint unavailable', requests_error: 'requests endpoint unavailable',
      })))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent] }), { status: 200 }))
    }))
    renderBudgets('account')
    expect(await screen.findByText('tiers endpoint unavailable')).toBeInTheDocument()
    expect(screen.getByText('requests endpoint unavailable')).toBeInTheDocument()
  })

  test('does not mutate until tier create confirmation and manages request approval', async () => {
    const fetchMock = vi.fn((input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({
        tiers: [{ tier_id: 'tier-1', name: 'Starter', is_default: false, cycle_acu_limit: 50, policy: 'manual', max_limit: null, priority: 1, member_count: 2, created_at: '2026-01-01' }],
        requests: [{ request_id: 7, name: 'Alice', email: 'alice@example.com', tier_id: 'tier-1', tier_name: 'Starter', current_cycle_acu_limit: 50, requested_cycle_acu_limit: 60, message: 'Need more room', status: 'pending', created_at: '2026-01-01' }],
        availability: { tiers: true, requests: true },
      })))
      if (url === '/__dag_tier_create') return Promise.resolve(new Response(JSON.stringify({ ok: true, tier: { tier_id: 'tier-2' } }), { status: 201 }))
      if (url === '/__dag_request_decide') return Promise.resolve(new Response(JSON.stringify({ ok: true, request: { request_id: 7, status: 'approved' } }), { status: 200 }))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))
    })
    vi.stubGlobal('fetch', fetchMock)
    renderBudgets('child')
    expect(await screen.findByText('Starter')).toBeInTheDocument()
    expect(await screen.findByText('Alice')).toBeInTheDocument()
    expect(await screen.findByText('alice@example.com')).toBeInTheDocument()
    await screen.findByRole('button', { name: 'Manage tiers' })
    fireEvent.click(screen.getByRole('button', { name: 'Manage tiers' }))
    fireEvent.click(screen.getByRole('button', { name: 'Create tier' }))
    fireEvent.change(screen.getByLabelText('Tier name'), { target: { value: 'Burst' } })
    fireEvent.change(screen.getByLabelText('Tier monthly ACUs'), { target: { value: '75' } })
    expect(fetchMock.mock.calls.some(([input]) => String(input) === '/__dag_tier_create')).toBe(false)
    fireEvent.click(screen.getAllByRole('button', { name: 'Create tier' })[1])
    await waitFor(() => expect(fetchMock.mock.calls.some(([input]) => String(input) === '/__dag_tier_create')).toBe(true))
    await screen.findByRole('button', { name: 'Manage pending requests' })
    fireEvent.click(screen.getByRole('button', { name: 'Manage pending requests' }))
    fireEvent.click(screen.getByRole('button', { name: 'Approve request 7' }))
    expect(screen.getByLabelText('Approved request ACUs')).toHaveValue('60')
    fireEvent.click(screen.getByRole('button', { name: 'Approve request' }))
    await waitFor(() => expect(fetchMock.mock.calls.some(([input]) => String(input) === '/__dag_request_decide')).toBe(true))
  })

  test('tier edit preview preserves an existing non-manual policy', async () => {
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => {
      if (String(input).startsWith('/__dag_budget_detail')) return Promise.resolve(new Response(JSON.stringify({
        tiers: [{ tier_id: 'tier-1', name: 'Conditional', is_default: false, cycle_acu_limit: 50, policy: 'conditional', member_count: 1 }],
        requests: [], availability: { tiers: true, requests: true },
      })))
      return Promise.resolve(new Response(JSON.stringify({ items: [parent, child, sibling] }), { status: 200 }))
    }))
    renderBudgets('child')
    await screen.findByRole('button', { name: 'Manage tiers' })
    fireEvent.click(screen.getByRole('button', { name: 'Manage tiers' }))
    fireEvent.click(screen.getByRole('button', { name: 'Edit tier Conditional' }))
    expect(document.querySelector('.tier-preview')?.textContent).toContain('Policy: conditional · policy unchanged')
  })
})
