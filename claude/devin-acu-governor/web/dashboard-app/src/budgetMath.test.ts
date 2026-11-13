import { describe, expect, test } from 'vitest'
import { allocationSummary, allocatedChildren, descendantOrgIds, effectiveBudget, parseLimitInput } from './budgetMath'
import type { Budget } from './types'

const budget = (id: string, parent_budget_id: string | null, monthly: number | null, status = 'active'): Budget => ({
  budget_id: id,
  name: id,
  parent_budget_id,
  org_ids: [],
  status,
  cycle_acu_limit: monthly,
  temporary_cycle_acu_limit: null,
})

describe('budget math', () => {
  test('uses temporary limits and preserves unbounded allocations as null', () => {
    expect(effectiveBudget({ ...budget('a', null, 10), temporary_cycle_acu_limit: 4 })).toBe(4)
    expect(allocatedChildren([budget('a', null, null)])).toBeNull()
  })

  test('replaces a child proposal and reports parent/root allocation', () => {
    const budgets = [budget('root', null, 100), budget('parent', 'root', 80), budget('child', 'parent', 60), budget('other', 'parent', 30)]
    const summary = allocationSummary(budgets, 'child', 70, null)
    expect(summary.parentLimit).toBe(80)
    expect(summary.allocated).toBe(100)
    expect(summary.over).toBe(true)
    expect(summary.rootLimit).toBe(100)
    expect(summary.rootAllocated).toBe(80)
  })

  test('guards cycles while collecting descendant organizations', () => {
    const budgets = [
      { ...budget('a', 'b', 10), org_ids: ['org-a'] },
      { ...budget('b', 'a', 10), org_ids: ['org-b'] },
    ]
    expect([...descendantOrgIds(budgets, 'a').ids]).toEqual(['org-a', 'org-b'])
  })

  test('accepts only empty or nonnegative integer text', () => {
    expect(parseLimitInput('')).toEqual({ valid: true, value: null })
    expect(parseLimitInput('0')).toEqual({ valid: true, value: 0 })
    expect(parseLimitInput('10')).toEqual({ valid: true, value: 10 })
    for (const value of [' ', ' 1', '+1', '-1', '1.5', '01']) expect(parseLimitInput(value).valid).toBe(false)
  })

  test('keeps zero-cap allocation arithmetic finite', () => {
    const budgets = [budget('root', null, 0), budget('child', 'root', 0)]
    const summary = allocationSummary(budgets, 'root', 0, null)
    expect(summary.allocated).toBe(0)
    expect(summary.rootLimit).toBe(0)
    expect(summary.over).toBe(false)
  })
})
