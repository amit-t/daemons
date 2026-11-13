import { useEffect, useMemo, useState } from 'react'
import {
  allocationSummary,
  allocatedChildren,
  descendantOrgIds,
  directActiveChildren,
  effectiveBudget,
  parseLimitInput,
} from '../budgetMath'
import { fmt } from '../format'
import type { Budget, BudgetDetail, OrgRow } from '../types'

interface Props {
  budgets: Budget[]
  orgs: OrgRow[]
  selectedId?: string
  onBudgets: (budgets: Budget[]) => void
  refreshNow: () => void
}

function limit(value: number | null): string {
  return value === null ? 'Unbounded' : `${fmt(value)} ACUs`
}

function usage(budget: Budget, budgets: Budget[], orgs: OrgRow[]) {
  const { ids } = descendantOrgIds(budgets, budget.budget_id)
  const linked = new Set<string>()
  const rows = orgs.filter((org) => ids.has(org.org_id) && !linked.has(org.org_id) && linked.add(org.org_id))
  return {
    consumed: rows.reduce((sum, org) => sum + org.consumed, 0),
    projected: rows.reduce((sum, org) => sum + org.projected, 0),
    missing: Math.max(0, ids.size - rows.length),
  }
}

function Meter({ consumed, projected, budget }: { consumed: number; projected: number; budget: Budget }) {
  const cap = effectiveBudget(budget)
  const blocked = cap === 0 && consumed === 0
  const over = cap !== null && projected > cap
  const ratio = cap === null || cap === 0 ? (cap === 0 && consumed > 0 ? 100 : 0) : Math.min(100, (consumed / cap) * 100)
  return (
    <div className="budget-meter-wrap">
      <div className={`meter ${over ? 'over' : ''}`} aria-label={`snapshot consumed ${fmt(consumed)} of ${limit(cap)}`}>
        <i style={{ width: `${ratio}%` }} />
      </div>
      <div className="budget-meter-label">
        <span>snapshot consumed {fmt(consumed)}</span>
        <span>{cap === null ? 'unbounded' : `snapshot projected ${fmt(projected)} / ${fmt(cap)}`}</span>
        {blocked && <strong className="warning-text">BLOCKED</strong>}
        {over && <strong className="warning-text">PROJECTED OVER</strong>}
      </div>
    </div>
  )
}

function BudgetCard({
  budget,
  budgets,
  orgs,
  depth,
  visited,
  onOpen,
}: {
  budget: Budget
  budgets: Budget[]
  orgs: OrgRow[]
  depth: number
  visited: Set<string>
  onOpen: (id: string) => void
}) {
  const repeated = visited.has(budget.budget_id)
  const nextVisited = new Set(visited).add(budget.budget_id)
  const children = repeated ? [] : directActiveChildren(budgets, budget.budget_id)
  const u = usage(budget, budgets, orgs)
  return (
    <div className="budget-tree-node" style={{ marginLeft: `${depth * 18}px` }}>
      <button type="button" className="budget-card" onClick={() => onOpen(budget.budget_id)}>
        <div className="budget-card-top"><strong>{budget.name || budget.budget_id}</strong><span className={`status ${budget.status}`}>{budget.status}</span></div>
        <div className="budget-card-id">{budget.budget_id}</div>
        <BudgetAllocation budget={budget} budgets={budgets} />
        <Meter consumed={u.consumed} projected={u.projected} budget={budget} />
        {u.missing > 0 && <div className="warning-text">Usage incomplete: {u.missing} linked organization{u.missing === 1 ? '' : 's'} missing from snapshot.</div>}
        {repeated && <div className="warning-text">Cycle detected; tree expansion stopped.</div>}
      </button>
      {children.length > 0 && <div className="budget-children">{children.map((child) => <BudgetCard key={child.budget_id} budget={child} budgets={budgets} orgs={orgs} depth={depth + 1} visited={nextVisited} onOpen={onOpen} />)}</div>}
    </div>
  )
}

function BudgetAllocation({ budget, budgets }: { budget: Budget; budgets: Budget[] }) {
  const allocated = allocatedChildren(directActiveChildren(budgets, budget.budget_id))
  return (
    <div className="budget-allocation">
      <span>effective allocation <b>{limit(effectiveBudget(budget))}</b></span>
      <span>direct child allocated <b>{allocated === null ? 'Unbounded' : `${fmt(allocated)} ACUs`}</b></span>
    </div>
  )
}

function Editor({
  budget,
  budgets,
  orgs,
  onClose,
  onSaved,
  onStale,
  onPartialSuccess,
}: {
  budget: Budget
  budgets: Budget[]
  orgs: OrgRow[]
  onClose: () => void
  onSaved: (budget: Budget) => void
  onStale: () => void
  onPartialSuccess: () => void
}) {
  const [monthly, setMonthly] = useState(budget.cycle_acu_limit == null ? '' : String(budget.cycle_acu_limit))
  const [temporary, setTemporary] = useState(budget.temporary_cycle_acu_limit == null ? '' : String(budget.temporary_cycle_acu_limit))
  const [ack, setAck] = useState(false)
  const [saving, setSaving] = useState(false)
  const [stale, setStale] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const monthlyParsed = parseLimitInput(monthly)
  const temporaryParsed = parseLimitInput(temporary)
  const valid = monthlyParsed.valid && temporaryParsed.valid
  const unchanged = monthlyParsed.value === budget.cycle_acu_limit && temporaryParsed.value === budget.temporary_cycle_acu_limit
  const expectedAllocation = allocationSummary(budgets, budget.budget_id, budget.cycle_acu_limit, budget.temporary_cycle_acu_limit)
  const summary = allocationSummary(budgets, budget.budget_id, monthlyParsed.value, temporaryParsed.value)
  const currentUsage = usage(budget, budgets, orgs)
  const proposedEffective = temporaryParsed.value ?? monthlyParsed.value
  const belowConsumed = proposedEffective !== null && proposedEffective < currentUsage.consumed
  const belowProjected = proposedEffective !== null && proposedEffective < currentUsage.projected
  const archived = budget.status === 'archived'
  const updateInput = (setter: (value: string) => void, value: string) => {
    setter(value)
    setAck(false)
    setError(null)
  }
  const save = async () => {
    if (!valid || unchanged || archived || stale || (summary.over && !ack)) return
    setSaving(true)
    setError(null)
    try {
      const response = await fetch('/__dag_budget_update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-DAG-Write': '1' },
        body: JSON.stringify({
          budget_id: budget.budget_id,
          cycle_acu_limit: monthlyParsed.value,
          temporary_cycle_acu_limit: temporaryParsed.value,
          expected_cycle_acu_limit: budget.cycle_acu_limit,
          expected_temporary_cycle_acu_limit: budget.temporary_cycle_acu_limit,
          expected_parent_effective: expectedAllocation.parentLimit,
          expected_parent_allocated: expectedAllocation.allocated,
          expected_root_effective: expectedAllocation.rootLimit,
          confirm: 'UPDATE BUDGET',
        }),
      })
      const body = await response.json().catch(() => ({}))
      if (response.status === 409) {
        setStale(true)
        setError('This budget changed on the server. Refresh budgets and reopen the editor to review the current proposal.')
        onStale()
        return
      }
      if (body.partial_success) {
        setError('AMBIGUOUS RESULT: the update may have applied, but live verification failed. Refresh budgets before retrying.')
        onPartialSuccess()
        return
      }
      if (!response.ok) throw new Error(body.error || `Budget update failed (HTTP ${response.status})`)
      onSaved(body.budget as Budget)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause))
    } finally {
      setSaving(false)
    }
  }
  return (
    <div className="dialog-backdrop" role="presentation">
      <section className="dialog" role="dialog" aria-modal="true" aria-labelledby="budget-editor-title">
        <div className="dialog-heading"><h3 id="budget-editor-title">Edit budget limits</h3><button type="button" onClick={onClose}>×</button></div>
        <p className="panel-note">Empty means unbounded. Parent limits enforce actual usage; child allocations may exceed the parent after acknowledgement.</p>
        {archived && <div className="form-error">Archived budgets are read-only.</div>}
        <label>Monthly limit<input aria-label="Monthly limit" inputMode="numeric" value={monthly} onChange={(event) => updateInput(setMonthly, event.target.value)} /></label>
        <label>Temporary limit<input aria-label="Temporary limit" inputMode="numeric" value={temporary} onChange={(event) => updateInput(setTemporary, event.target.value)} /></label>
        {!valid && <div className="form-error">Limits must be empty or nonnegative integer text.</div>}
        {unchanged && <div className="panel-note">No changes requested.</div>}
        <div className={`allocation-preview ${summary.over ? 'warning' : ''}`}>
          <b>{summary.over ? 'Parent allocation warning' : 'Parent allocation preview'}</b>
          <span>Effective parent budget: {limit(summary.parentLimit)}</span>
          <span>Active direct child allocation: {summary.allocated === null ? 'Unbounded' : `${fmt(summary.allocated)} ACUs`}</span>
          {summary.parentLimit !== null && summary.allocated !== null && <span>Delta: {fmt(summary.allocated - summary.parentLimit)} ACUs</span>}
          {summary.rootLimit !== summary.parentLimit && <span>Account root effective budget: {limit(summary.rootLimit)}; direct child allocation unchanged at {summary.rootAllocated === null ? 'Unbounded' : `${fmt(summary.rootAllocated)} ACUs`}.</span>}
          {summary.over && <span className="warning-text">Proposed allocation exceeds the parent. The API permits this; actual usage remains enforced by the parent.</span>}
        </div>
        {belowConsumed && <div className="form-error">Proposed effective limit {fmt(proposedEffective)} is below snapshot consumed {fmt(currentUsage.consumed)}; this likely blocks new work.</div>}
        {belowProjected && <div className="form-error">Proposed effective limit {fmt(proposedEffective)} is below snapshot projected {fmt(currentUsage.projected)}; risk exists before cycle end.</div>}
        {currentUsage.missing > 0 && <div className="panel-note">Snapshot usage estimate incomplete: {currentUsage.missing} linked organization{currentUsage.missing === 1 ? '' : 's'} missing.</div>}
        {summary.over && <label className="checkbox"><input type="checkbox" checked={ack} onChange={(event) => setAck(event.target.checked)} /> I understand the parent allocation warning</label>}
        {error && <div className="form-error">{error}</div>}
        <div className="dialog-actions"><button type="button" onClick={onClose}>Cancel</button><button type="button" className="primary" disabled={saving || !valid || unchanged || archived || stale || (summary.over && !ack)} onClick={() => void save()}>{saving ? 'Saving…' : 'Save limits'}</button></div>
      </section>
    </div>
  )
}

const detailFields: Record<string, string[]> = {
  Tiers: ['tier_id', 'name', 'cycle_acu_limit', 'member_count', 'policy', 'is_default'],
  'Pending requests': ['request_id', 'name', 'email', 'current_cycle_acu_limit', 'requested_cycle_acu_limit', 'status'],
}

function ReadOnlyList({ title, values, available, error }: { title: string; values: Array<Record<string, unknown>>; available?: boolean; error?: string }) {
  const fields = detailFields[title] ?? []
  const display = (value: unknown) => value == null ? '—' : typeof value === 'object' ? JSON.stringify(value) : String(value)
  return (
    <section className="panel">
      <h2 className="panel-title">{title}</h2>
      {available === false ? <p className="panel-note">{error ?? `${title} unavailable on this Devin deployment.`}</p> : values.length === 0 ? <p className="empty">No {title.toLowerCase()}.</p> : (
        <div className="table-wrap"><table><thead><tr>{fields.map((field) => <th key={field}>{field.replaceAll('_', ' ')}</th>)}</tr></thead><tbody>{values.map((value, index) => <tr key={index}>{fields.map((field) => <td key={field}>{display(value[field])}</td>)}</tr>)}</tbody></table></div>
      )}
    </section>
  )
}

function tierId(tier: Record<string, unknown>): string {
  return String(tier.tier_id ?? tier.id ?? '')
}

function requestId(request: Record<string, unknown>): number {
  return Number(request.request_id ?? request.id)
}

function ManagementError({ message }: { message: string | null }) {
  return message ? <div className="form-error">{message}</div> : null
}

function TierForm({
  budget,
  tier,
  onCancel,
  onComplete,
  onIssue,
}: {
  budget: Budget
  tier?: Record<string, unknown>
  onCancel: () => void
  onComplete: () => void
  onIssue: (message: string) => void
}) {
  const editing = Boolean(tier)
  const [name, setName] = useState(String(tier?.name ?? ''))
  const [limitText, setLimitText] = useState(tier?.cycle_acu_limit == null ? '' : String(tier.cycle_acu_limit))
  const [saving, setSaving] = useState(false)
  const parsed = parseLimitInput(limitText)
  const unchanged = editing && name === String(tier?.name ?? '') && parsed.value === (tier?.cycle_acu_limit ?? null)
  const policy = editing ? String(tier?.policy ?? 'manual') : 'manual'
  const save = async () => {
    if (!parsed.valid || !name.trim() || name.length > 120 || unchanged) return
    setSaving(true)
    try {
      const path = editing ? '/__dag_tier_update' : '/__dag_tier_create'
      const body = editing
        ? {
            budget_id: budget.budget_id,
            tier_id: tierId(tier!),
            name,
            cycle_acu_limit: parsed.value,
            expected_name: String(tier?.name ?? ''),
            expected_cycle_acu_limit: tier?.cycle_acu_limit ?? null,
            confirm: 'UPDATE TIER',
          }
        : { budget_id: budget.budget_id, name, cycle_acu_limit: parsed.value, confirm: 'CREATE TIER' }
      const response = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-DAG-Write': '1' }, body: JSON.stringify(body) })
      const result = await response.json().catch(() => ({}))
      if (!response.ok || result.partial_success) {
        onIssue(result.partial_success ? 'AMBIGUOUS RESULT: tier mutation may have applied; live detail was reloaded.' : result.error || `Tier mutation failed (HTTP ${response.status})`)
        return
      }
      onComplete()
    } catch (cause) {
      onIssue(cause instanceof Error ? cause.message : String(cause))
    } finally {
      setSaving(false)
    }
  }
  return (
    <section className="management-form" aria-label={editing ? 'Edit tier' : 'Create tier'}>
      <h4>{editing ? 'Edit tier' : 'Create tier'}</h4>
      <label>Tier name<input aria-label="Tier name" value={name} onChange={(event) => setName(event.target.value)} /></label>
      <label>Monthly ACUs<input aria-label="Tier monthly ACUs" inputMode="numeric" value={limitText} onChange={(event) => setLimitText(event.target.value)} /></label>
      <div className="tier-preview">Policy: <b>{policy}</b>{editing ? ' · policy unchanged' : ''} · limit: <b>{parsed.valid ? limit(parsed.value) : 'invalid'}</b></div>
      {(!parsed.valid || !name.trim() || name.length > 120) && <div className="form-error">Name and monthly ACUs must be valid before saving.</div>}
      <div className="dialog-actions"><button type="button" onClick={onCancel}>Cancel</button><button type="button" className="primary" disabled={saving || !parsed.valid || !name.trim() || name.length > 120 || unchanged} onClick={() => void save()}>{saving ? 'Saving…' : editing ? 'Update tier' : 'Create tier'}</button></div>
    </section>
  )
}

function TierManager({ budget, tiers, onChanged, onIssue }: { budget: Budget; tiers: Array<Record<string, unknown>>; onChanged: () => void; onIssue: (message: string) => void }) {
  const [editing, setEditing] = useState<Record<string, unknown> | null | undefined>(undefined)
  return (
    <section className="management-panel" aria-label="Manage tiers">
      <div className="management-heading"><h3>Manage tiers</h3><button type="button" onClick={() => setEditing(null)}>Create tier</button></div>
      {editing !== undefined && <TierForm budget={budget} tier={editing ?? undefined} onCancel={() => setEditing(undefined)} onComplete={() => { setEditing(undefined); onChanged() }} onIssue={(message) => { setEditing(undefined); onIssue(message) }} />}
      <div className="management-list">{tiers.map((tier) => <div className="management-row" key={tierId(tier)}><span><b>{String(tier.name ?? tierId(tier))}</b> · {limit((tier.cycle_acu_limit as number | null | undefined) ?? null)} · {String(tier.member_count ?? 0)} members</span><button type="button" aria-label={`Edit tier ${String(tier.name ?? tierId(tier))}`} onClick={() => setEditing(tier)}>Edit tier</button></div>)}</div>
    </section>
  )
}

function RequestDecision({
  budget,
  request,
  onCancel,
  onChanged,
  onIssue,
}: {
  budget: Budget
  request: Record<string, unknown>
  onCancel: () => void
  onChanged: () => void
  onIssue: (message: string) => void
}) {
  const approving = requestDecisionAction(request)
  const [limitText, setLimitText] = useState(String(request.requested_cycle_acu_limit ?? request.cycle_acu_limit ?? ''))
  const parsed = parseLimitInput(limitText)
  const [saving, setSaving] = useState(false)
  const decide = async () => {
    if (approving === 'approve' && !parsed.valid) return
    setSaving(true)
    try {
      const response = await fetch('/__dag_request_decide', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-DAG-Write': '1' },
        body: JSON.stringify({
          budget_id: budget.budget_id,
          request_id: requestId(request),
          action: approving,
          cycle_acu_limit: approving === 'approve' ? parsed.value : null,
          expected_requested_cycle_acu_limit: request.requested_cycle_acu_limit ?? request.cycle_acu_limit,
          confirm: approving === 'approve' ? 'APPROVE REQUEST' : 'DENY REQUEST',
        }),
      })
      const result = await response.json().catch(() => ({}))
      if (!response.ok || result.partial_success) {
        onIssue(result.partial_success ? 'AMBIGUOUS RESULT: request decision may have applied; live detail was reloaded.' : result.error || `Request decision failed (HTTP ${response.status})`)
        return
      }
      onChanged()
    } catch (cause) {
      onIssue(cause instanceof Error ? cause.message : String(cause))
    } finally {
      setSaving(false)
    }
  }
  return (
    <div className="dialog-backdrop" role="presentation">
      <section className="dialog" role="dialog" aria-modal="true" aria-labelledby="request-decision-title">
        <h3 id="request-decision-title">{approving === 'approve' ? 'Approve request' : 'Deny request'}</h3>
        {approving === 'approve' && <label>Approved monthly ACUs<input aria-label="Approved request ACUs" inputMode="numeric" value={limitText} onChange={(event) => setLimitText(event.target.value)} /></label>}
        <p className="panel-note">{approving === 'approve' ? 'Approval applies the selected limit.' : 'Denying is irreversible for this request.'}</p>
        {approving === 'approve' && !parsed.valid && <div className="form-error">Approval limit must be a nonnegative integer.</div>}
        <div className="dialog-actions"><button type="button" onClick={onCancel}>Cancel</button><button type="button" className="primary" disabled={saving || (approving === 'approve' && !parsed.valid)} onClick={() => void decide()}>{saving ? 'Saving…' : approving === 'approve' ? 'Approve request' : 'Deny request'}</button></div>
      </section>
    </div>
  )
}

function requestDecisionAction(request: Record<string, unknown>): 'approve' | 'deny' {
  return request.status === 'pending' ? 'approve' : 'deny'
}

function RequestManager({ budget, requests, onChanged, onIssue }: { budget: Budget; requests: Array<Record<string, unknown>>; onChanged: () => void; onIssue: (message: string) => void }) {
  const [decision, setDecision] = useState<Record<string, unknown> | null>(null)
  return (
    <section className="management-panel" aria-label="Manage pending requests">
      <div className="management-heading"><h3>Manage pending requests</h3><span>{requests.length} pending</span></div>
      <div className="management-list">{requests.map((request) => {
        const id = requestId(request)
        return <div className="management-row request-row" key={id}><div><b>{String(request.name ?? `Request ${id}`)}</b><span>{String(request.email ?? '')}</span><span>Current {limit((request.current_cycle_acu_limit as number | null | undefined) ?? null)} · requested {limit((request.requested_cycle_acu_limit as number | null | undefined) ?? null)}</span><span>{String(request.message ?? '')}</span></div><div><button type="button" aria-label={`Approve request ${id}`} onClick={() => setDecision(request)}>Approve</button><button type="button" aria-label={`Deny request ${id}`} onClick={() => setDecision({ ...request, status: 'denying' })}>Deny</button></div></div>
      })}</div>
      {decision && <RequestDecision budget={budget} request={decision} onCancel={() => setDecision(null)} onChanged={() => { setDecision(null); onChanged() }} onIssue={(message) => { setDecision(null); onIssue(message) }} />}
    </section>
  )
}

function budgetDepth(budget: Budget, budgets: Budget[]): number {
  let depth = 0
  let current = budget
  const visited = new Set<string>()
  while (current.parent_budget_id && !visited.has(current.budget_id)) {
    visited.add(current.budget_id)
    const parent = budgets.find((item) => item.budget_id === current.parent_budget_id)
    if (!parent) break
    depth += 1
    current = parent
  }
  return depth
}

function Utilization({ budget, consumed, projected }: { budget: Budget; consumed: number; projected: number }) {
  const cap = effectiveBudget(budget)
  const ratio = cap === null || cap === 0 ? 0 : Math.min(100, consumed / cap * 100)
  const over = cap !== null && projected > cap
  return (
    <div className="budget-utilization">
      <span>{fmt(consumed)} / {limit(cap)}</span>
      {cap !== null && <span>{cap === 0 ? '0%' : `${((consumed / cap) * 100).toFixed(1)}%`}</span>}
      <span className={`budget-util-bar ${over ? 'over' : ''}`}><i style={{ width: `${ratio}%` }} /></span>
      {over && <strong className="warning-text">over</strong>}
      {cap === 0 && consumed === 0 && <strong className="warning-text">blocked</strong>}
    </div>
  )
}

function RootSummary({ root, budgets, orgs }: { root: Budget; budgets: Budget[]; orgs: OrgRow[] }) {
  const children = directActiveChildren(budgets, root.budget_id)
  const allocated = allocatedChildren(children)
  const rootLimit = effectiveBudget(root)
  const overage = rootLimit !== null && allocated !== null ? Math.max(0, allocated - rootLimit) : null
  const percent = rootLimit === null
    ? 'unbounded allocation'
    : rootLimit === 0
      ? allocated === 0 ? '0% allocated' : 'over zero-cap account'
      : allocated === null ? 'unbounded allocation' : `${((allocated / rootLimit) * 100).toFixed(1)}% allocated`
  const over = children.filter((child) => {
    const row = usage(child, budgets, orgs)
    const cap = effectiveBudget(child)
    return cap !== null && row.projected > cap
  }).length
  return <div className="budget-root-summary"><b>{children.length} active children</b><span>{allocated === null ? 'Unbounded direct child allocation' : `${fmt(allocated)} / ${limit(rootLimit)}`}</span><span>{percent}</span>{overage !== null && overage > 0 && <strong className="warning-text">{fmt(overage)} ACUs over account budget</strong>}{allocated === null && rootLimit !== null && <strong className="warning-text">Unbounded child allocation exceeds finite account budget</strong>}{over > 0 && <strong className="warning-text">{over} projected over</strong>}</div>
}

function BudgetDetailPanel({
  budget,
  budgets,
  orgs,
  onBack,
  onSaved,
  onStale,
  onPartialSuccess,
  notice,
}: {
  budget: Budget
  budgets: Budget[]
  orgs: OrgRow[]
  onBack: () => void
  onSaved: (budget: Budget) => void
  onStale: () => void
  onPartialSuccess: () => void
  notice?: string | null
}) {
  const [detail, setDetail] = useState<BudgetDetail | null>(null)
  const [detailError, setDetailError] = useState<string | null>(null)
  const [managementError, setManagementError] = useState<string | null>(null)
  const [editing, setEditing] = useState(false)
  const [manageTiers, setManageTiers] = useState(false)
  const [manageRequests, setManageRequests] = useState(false)
  const u = usage(budget, budgets, orgs)
  const loadDetail = async () => {
    setDetail(null)
    setDetailError(null)
    try {
      const response = await fetch(`/__dag_budget_detail?budget_id=${encodeURIComponent(budget.budget_id)}`, { cache: 'no-store' })
      const body = await response.json()
      if (!response.ok) throw new Error(body.error || `Detail unavailable (HTTP ${response.status})`)
      setDetail(body)
    } catch (cause) {
      setDetailError(cause instanceof Error ? cause.message : String(cause))
    }
  }
  useEffect(() => {
    void loadDetail()
  }, [budget.budget_id])
  const managementIssue = (message: string) => {
    setManagementError(message)
    void loadDetail()
  }
  return (
    <section className="budget-detail">
      <button type="button" className="back-link" onClick={onBack}>← All budgets</button>
      <div className="detail-heading"><div><div className="eyebrow">Budget detail</div><h2>{budget.name || budget.budget_id}</h2><div className="budget-card-id">{budget.budget_id}</div></div><button type="button" className="primary" disabled={budget.status === 'archived'} onClick={() => setEditing(true)}>Edit limits</button></div>
      <div className="cards budget-summary-cards">
        <div className="card"><div className="card-label">Snapshot consumed</div><div className="card-value">{fmt(u.consumed)}</div><div className="card-sub">linked organization snapshot</div></div>
        <div className="card"><div className="card-label">Snapshot projected</div><div className="card-value">{fmt(u.projected)}</div><div className="card-sub">cycle end estimate</div></div>
        <div className="card"><div className="card-label">Effective budget</div><div className="card-value">{limit(effectiveBudget(budget))}</div><div className="card-sub">{budget.temporary_cycle_acu_limit != null ? 'temporary limit active' : 'monthly limit'}</div></div>
      </div>
      <section className="panel"><h2 className="panel-title">Usage</h2><Meter consumed={u.consumed} projected={u.projected} budget={budget} /><p className="panel-note">Figures are derived from the data.json organization snapshot. Consumption is summed once per linked organization across this budget’s descendants; allocation limits are not consumption.</p>{u.missing > 0 && <p className="warning-text">Usage may be incomplete: {u.missing} linked organization{u.missing === 1 ? '' : 's'} are missing from this snapshot.</p>}</section>
      {notice && <div className="form-error"><strong>{notice.startsWith('AMBIGUOUS') ? 'AMBIGUOUS RESULT: ' : ''}</strong>{notice.replace(/^AMBIGUOUS RESULT:\s*/, '')}</div>}
      <div className="panel-grid">
        <section className="panel"><h2 className="panel-title">Budget policy</h2><dl className="budget-facts"><dt>Parent</dt><dd>{budget.parent_budget_id ?? 'Account root'}</dd><dt>Monthly</dt><dd>{limit(budget.cycle_acu_limit)}</dd><dt>Temporary</dt><dd>{limit(budget.temporary_cycle_acu_limit)}</dd><dt>Organizations</dt><dd>{budget.org_ids?.length ?? 0}</dd></dl></section>
        <section className="panel"><h2 className="panel-title">Linked organizations</h2><div className="org-tabs">{(budget.org_ids ?? []).map((id) => <a key={id} className="org-tab" href={`#/org/${encodeURIComponent(id)}`}>{orgs.find((org) => org.org_id === id)?.name ?? id}</a>)}</div></section>
      </div>
      {managementError && <ManagementError message={managementError} />}
      <div className="panel-grid">
        <section className="management-section">
          <ReadOnlyList title="Tiers" values={detail?.tiers ?? []} available={detail?.availability.tiers} error={detail?.tiers_error} />
          {budget.status === 'active' && detail?.availability.tiers === true && <button type="button" className="manage-button" aria-label="Manage tiers" onClick={() => setManageTiers((value) => !value)}>{manageTiers ? 'Hide tier manager' : 'Manage tiers'}</button>}
          {manageTiers && detail?.availability.tiers === true && <TierManager budget={budget} tiers={detail.tiers} onChanged={() => { setManagementError(null); void loadDetail() }} onIssue={managementIssue} />}
        </section>
        <section className="management-section">
          <ReadOnlyList title="Pending requests" values={detail?.requests ?? []} available={detail?.availability.requests} error={detail?.requests_error} />
          {budget.status === 'active' && detail?.availability.requests === true && <button type="button" className="manage-button" aria-label="Manage pending requests" onClick={() => setManageRequests((value) => !value)}>{manageRequests ? 'Hide request manager' : 'Manage requests'}</button>}
          {manageRequests && detail?.availability.requests === true && <RequestManager budget={budget} requests={detail.requests} onChanged={() => { setManagementError(null); void loadDetail() }} onIssue={managementIssue} />}
        </section>
      </div>
      {detailError && <div className="form-error">{detailError}</div>}
      {editing && <Editor budget={budget} budgets={budgets} orgs={orgs} onClose={() => setEditing(false)} onSaved={(saved) => { setEditing(false); onSaved(saved) }} onStale={() => { setEditing(false); onStale() }} onPartialSuccess={() => { setEditing(false); onPartialSuccess() }} />}
    </section>
  )
}

export function Budgets({ budgets, orgs, selectedId, onBudgets, refreshNow }: Props) {
  const [tab, setTab] = useState<'account' | 'organizations'>('account')
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState('all')
  const [loading, setLoading] = useState(false)
  const [loaded, setLoaded] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [ambiguous, setAmbiguous] = useState(false)
  const load = async (clearError = true) => {
    setLoading(true)
    try {
      const response = await fetch('/__dag_budgets', { cache: 'no-store' })
      const body = await response.json()
      if (!response.ok) throw new Error(body.error || `Budgets unavailable (HTTP ${response.status})`)
      onBudgets(body.items ?? [])
      if (clearError) setError(null)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause))
    } finally {
      setLoading(false)
      setLoaded(true)
    }
  }
  useEffect(() => { void load() }, [])
  const filtered = useMemo(() => budgets.filter((budget) => (!query || `${budget.name} ${budget.budget_id}`.toLowerCase().includes(query.toLowerCase())) && (status === 'all' || budget.status === status)), [budgets, query, status])
  const open = (id: string) => { window.location.hash = `#/budget/${encodeURIComponent(id)}` }
  const selected = selectedId ? budgets.find((budget) => budget.budget_id === selectedId) : null
  const update = (saved: Budget) => { onBudgets(budgets.map((budget) => budget.budget_id === saved.budget_id ? saved : budget)); refreshNow(); void load() }
  const refetchAfterConflict = () => { setError('Budget changed on the server; live budgets were refreshed. Reopen the editor to review the current proposal.'); void load(false) }
  const refetchAfterPartial = () => { setAmbiguous(true); setError('AMBIGUOUS RESULT: the last update may have applied, but live verification failed. Current budgets were re-fetched; review before retrying.'); void load(false) }
  if (selectedId && !selected && loaded && !loading) return <section className="budget-detail"><button type="button" className="back-link" onClick={() => { window.location.hash = '#/budgets' }}>← All budgets</button><div className="form-error">Budget {selectedId} was not found in the live budget response.</div></section>
  if (selected) return <BudgetDetailPanel budget={selected} budgets={budgets} orgs={orgs} notice={error} onBack={() => { window.location.hash = '#/budgets' }} onSaved={update} onStale={refetchAfterConflict} onPartialSuccess={refetchAfterPartial} />
  return (
    <section className="budgets-page">
      <div className="detail-heading"><div><div className="eyebrow">Enterprise usage policies</div><h2>Budgets</h2><p className="panel-note">Live allocation tree. Parent limits enforce actual usage; child allocations are planning signals and can exceed a parent.</p></div><button type="button" onClick={() => void load()}>{loading ? 'Refreshing…' : 'Refresh budgets'}</button></div>
      {ambiguous && <div className="form-error"><strong>AMBIGUOUS RESULT:</strong> the last update may have applied, but live verification failed. Current budgets were re-fetched; review before retrying.</div>}
      <div className="budget-tabs" role="tablist"><button type="button" className={tab === 'account' ? 'active' : ''} onClick={() => setTab('account')}>Account tree</button><button type="button" className={tab === 'organizations' ? 'active' : ''} onClick={() => setTab('organizations')}>Organizations</button></div>
      {error && <div className="form-error">{error}</div>}
      {tab === 'account' ? <div className="budget-tree">{budgets.filter((budget) => budget.status === 'active' && !budget.parent_budget_id).map((budget) => <div className="budget-tree-root" key={budget.budget_id}><BudgetCard budget={budget} budgets={budgets} orgs={orgs} depth={0} visited={new Set()} onOpen={open} /><RootSummary root={budget} budgets={budgets} orgs={orgs} /></div>)}{budgets.length === 0 && !loading && <p className="empty">No budgets returned by the live API.</p>}</div> : <div className="org-budget-grid">{orgs.map((org) => <div className="org-budget-card" key={org.org_id}><strong>{org.name}</strong><span>{org.org_id}</span><span>snapshot consumed {fmt(org.consumed)} · snapshot projected {fmt(org.projected)}</span><div>{budgets.filter((budget) => budget.org_ids?.includes(org.org_id)).map((budget) => <button key={budget.budget_id} type="button" onClick={() => open(budget.budget_id)}>{budget.name || budget.budget_id}</button>)}</div></div>)}</div>}
      <section className="panel budget-table-panel"><div className="table-toolbar"><h2 className="panel-title">All budgets</h2><input aria-label="Search budgets" placeholder="Search budgets" value={query} onChange={(event) => setQuery(event.target.value)} /><select aria-label="Filter budget status" value={status} onChange={(event) => setStatus(event.target.value)}><option value="all">All statuses</option><option value="active">Active</option><option value="archived">Archived</option></select></div><div className="table-wrap"><table><thead><tr><th>Name</th><th>Linked org</th><th>ACU utilization</th><th>Status</th><th>Parent</th><th>Effective</th><th>Projected</th></tr></thead><tbody>{filtered.map((budget) => { const u = usage(budget, budgets, orgs); return <tr key={budget.budget_id} className="clickable" onClick={() => open(budget.budget_id)}><td><span style={{ marginLeft: `${budgetDepth(budget, budgets) * 18}px` }}>{budget.name || budget.budget_id}</span><div className="budget-card-id">{budget.budget_id}</div>{u.missing > 0 && <div className="warning-text">Usage incomplete: {u.missing} missing from snapshot</div>}</td><td>{(budget.org_ids ?? []).map((id) => orgs.find((org) => org.org_id === id)?.name ?? id).join(', ') || '—'}</td><td><Utilization budget={budget} consumed={u.consumed} projected={u.projected} /></td><td>{budget.status}</td><td>{budget.parent_budget_id ?? 'Account root'}</td><td>{limit(effectiveBudget(budget))}</td><td className={effectiveBudget(budget) !== null && u.projected > effectiveBudget(budget)! ? 'warning-text' : ''}>{fmt(u.projected)}</td></tr> })}</tbody></table></div></section>
    </section>
  )
}
