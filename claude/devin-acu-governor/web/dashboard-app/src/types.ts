// Shape of data.json as produced by lib/dashboard.jq.

export type OrgStatus = 'ok' | 'warning' | 'critical' | 'forecast_over' | 'over' | 'blocked' | 'uncapped'
export type UserStatus = 'ok' | 'warning' | 'critical' | 'over' | 'blocked' | 'uncapped'
export type CapSource = 'explicit' | 'default' | 'uncapped'

export interface CycleInfo {
  after: number
  before: number
  start_date: string
  end_date: string
  cycle_days: number
  elapsed_days: number
  left_days: number
}

export interface EnterpriseInfo {
  consumed: number
  remaining: number
  daily_run_rate: number
  projected_cycle_total: number
  projected_over_under: number
  verdict: 'OVER' | 'UNDER'
}

export interface ProductSplit {
  product: string
  acus: number
}

export interface CapTotals {
  effective_user_cycle_acu_limit: number
  capped_users: number
  uncapped_users: number
  zero_cap_users: number
}

export interface DailyPoint {
  date: string
  epoch: number
  acus: number
  devin: number
  cascade: number
  terminal: number
  review: number
}

export interface OrgRow {
  org_id: string
  name: string
  consumed: number
  daily_run_rate: number
  projected: number
  max_cycle_acu_limit: number | null
  max_session_acu_limit: number | null
  pct_limit: number | null
  status: OrgStatus
}

export interface UserRow {
  user_id: string
  email: string
  name: string
  consumed: number
  explicit_cycle_acu_limit: number | null
  default_cycle_acu_limit: number | null
  effective_cycle_acu_limit: number | null
  cap_source: CapSource
  billing_org_id: string | null
  headroom: number | null
  pct_limit: number | null
  status: UserStatus
}

export interface RefreshInfo {
  enabled: boolean
  interval_minutes: number | null
  interval_ms: number | null
}

export interface DashboardData {
  generated_at: string
  refresh: RefreshInfo
  cycle: CycleInfo
  pool: number
  enterprise: EnterpriseInfo
  cap_totals: CapTotals
  product_split: ProductSplit[]
  daily: DailyPoint[]
  orgs: OrgRow[]
  users: UserRow[]
  warnings: string[]
}
