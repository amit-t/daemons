export function fmt(n: number | null | undefined, digits = 2): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—'
  return n.toLocaleString('en-US', { maximumFractionDigits: digits })
}

export function fmtPct(ratio: number | null | undefined): string {
  if (ratio === null || ratio === undefined || Number.isNaN(ratio)) return '—'
  return (ratio * 100).toFixed(1) + '%'
}

export function relTime(iso: string): string {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return iso
  const s = Math.max(0, Math.round((Date.now() - t) / 1000))
  if (s < 60) return `${s}s ago`
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s ago`
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m ago`
}

// Coarse human duration for the refresh countdown: "45s" / "4m 32s" / "1h 5m".
// Mirrors lib/dashboard.zsh _dag_dash_fmt_dur so terminal and browser read alike.
export function fmtDur(seconds: number): string {
  const s = Math.max(0, Math.round(seconds))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
}

export function shortDay(date: string): string {
  // "2026-05-16" -> "May 16"
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
  const [, m, d] = date.split('-').map(Number)
  if (!m || !d) return date
  return `${months[m - 1]} ${d}`
}
