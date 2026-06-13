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

export interface UserProductTotals {
  devin: number
  cascade: number
  terminal: number
  review: number
}

export interface UserSessions {
  count: number
  acus: number
}

export interface ModelUsage {
  model: string
  acus: number
  messages: number
}

export interface IdeUsage {
  ide: string
  acus: number
  messages: number
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
  daily: DailyPoint[]
  product_totals: UserProductTotals
  sessions: UserSessions | null
  models: ModelUsage[]
  ides: IdeUsage[]
}

export interface SessionsInfo {
  available: boolean
  count: number
  acus: number
}

export interface ModelAnalyticsInfo {
  available: boolean
  stale: boolean
  reason: string | null
  fetched_at: string | null
  fetched_at_epoch: number | null
  start_date: string | null
  end_date: string | null
}

export interface RefreshInfo {
  enabled: boolean
  interval_minutes: number | null
  interval_ms: number | null
}

// status.json — the live refresh channel written by lib/dashboard.zsh next to
// data.json. Polled ~1s by the app to drive the countdown + progress bar.
export interface RefreshStatusFile {
  state: 'counting_down' | 'refreshing' | 'static'
  pct: number
  phase: string
  detail: string
  interval_seconds: number
  next_refresh_epoch: number | null
  updated_at_epoch: number
  generated_at: string | null
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
  sessions_info: SessionsInfo
  model_analytics: ModelAnalyticsInfo
  orgs: OrgRow[]
  users: UserRow[]
  warnings: string[]
}
