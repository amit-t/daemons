import type { Budget } from './types'

export function effectiveBudget(budget: Budget | null | undefined): number | null {
  return budget ? (budget.temporary_cycle_acu_limit ?? budget.cycle_acu_limit) : null
}

export function directActiveChildren(budgets: Budget[], parentId: string): Budget[] {
  return budgets.filter((budget) => budget.status === 'active' && budget.parent_budget_id === parentId)
}

export function allocatedChildren(children: Budget[]): number | null {
  return children.some((child) => effectiveBudget(child) === null)
    ? null
    : children.reduce((total, child) => total + effectiveBudget(child)!, 0)
}

export function allocationSummary(
  budgets: Budget[],
  targetId: string,
  monthly: number | null,
  temporary: number | null,
): {
  parentLimit: number | null
  allocated: number | null
  over: boolean
  parentId: string | null
  rootLimit: number | null
  rootAllocated: number | null
} {
  const target = budgets.find((budget) => budget.budget_id === targetId)
  if (!target) return { parentLimit: null, allocated: 0, over: false, parentId: null, rootLimit: null, rootAllocated: 0 }
  const proposed = temporary ?? monthly
  let root = target
  const visited = new Set<string>()
  while (root.parent_budget_id && !visited.has(root.budget_id)) {
    visited.add(root.budget_id)
    const parent = budgets.find((budget) => budget.budget_id === root.parent_budget_id)
    if (!parent) break
    root = parent
  }
  if (target.parent_budget_id) {
    const parent = budgets.find((budget) => budget.budget_id === target.parent_budget_id)
    const children = directActiveChildren(budgets, target.parent_budget_id).map((child) =>
      child.budget_id === targetId
        ? { ...child, cycle_acu_limit: proposed, temporary_cycle_acu_limit: null }
        : child,
    )
    const parentLimit = effectiveBudget(parent)
    const allocated = allocatedChildren(children)
    const rootAllocated = allocatedChildren(directActiveChildren(budgets, root.budget_id))
    return {
      parentLimit,
      allocated,
      over: parentLimit !== null && (allocated === null || allocated > parentLimit),
      parentId: parent?.budget_id ?? target.parent_budget_id,
      rootLimit: effectiveBudget(root),
      rootAllocated,
    }
  }
  const parentLimit = proposed
  const allocated = allocatedChildren(directActiveChildren(budgets, targetId))
  return {
    parentLimit,
    allocated,
    over: parentLimit !== null && (allocated === null || allocated > parentLimit),
    parentId: null,
    rootLimit: proposed,
    rootAllocated: allocated,
  }
}

export function parseLimitInput(value: string): { valid: boolean; value: number | null } {
  if (value === '') return { valid: true, value: null }
  if (!/^(0|[1-9]\d*)$/.test(value)) return { valid: false, value: null }
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) ? { valid: true, value: parsed } : { valid: false, value: null }
}

export function descendantOrgIds(budgets: Budget[], budgetId: string): { ids: Set<string>; missingLinks: number } {
  const ids = new Set<string>()
  const visited = new Set<string>()
  let missingLinks = 0
  const visit = (id: string) => {
    if (visited.has(id)) return
    visited.add(id)
    const budget = budgets.find((candidate) => candidate.budget_id === id)
    if (!budget) return
    for (const orgId of budget.org_ids ?? []) {
      if (ids.has(orgId)) missingLinks += 1
      ids.add(orgId)
    }
    for (const child of budgets) {
      if (child.status === 'active' && child.parent_budget_id === id) visit(child.budget_id)
    }
  }
  visit(budgetId)
  return { ids, missingLinks }
}
