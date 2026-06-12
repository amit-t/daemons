import { useEffect, useState } from 'react'
import { useDashboardData } from './useDashboardData'
import { fmt, relTime } from './format'
import { BurnChart } from './components/BurnChart'
import { ProductSplitPanel } from './components/ProductSplit'
import { OrgTable } from './components/OrgTable'
import { UserTable } from './components/UserTable'

// Re-render the "x ago" labels every 30s without refetching.
function useClock() {
  const [, setTick] = useState(0)
  useEffect(() => {
    const id = window.setInterval(() => setTick((t) => t + 1), 30_000)
    return () => window.clearInterval(id)
  }, [])
}

export default function App() {
  const { data, error, stale } = useDashboardData()
  useClock()

  if (!data) {
    return (
      <div className="boot">
        <h1 className="console-title">
          DAG <span className="dim">// ACU BURN CONSOLE</span>
        </h1>
        <p>{error ? '' : 'loading data.json…'}</p>
        {error && (
          <p className="boot-error">
            {error} — regenerate with: <code>dag dashboard</code>
          </p>
        )}
      </div>
    )
  }

  const { enterprise: ent, cycle, refresh } = data
  const cyclePct = Math.min(100, (cycle.elapsed_days / cycle.cycle_days) * 100)
  const burnPct = data.pool > 0 ? Math.min(100, (ent.consumed / data.pool) * 100) : 0

  return (
    <>
      <header className="console-header">
        <h1 className="console-title">
          DAG <span className="dim">// ACU BURN CONSOLE</span>
        </h1>
        <div className="console-meta">
          <span>
            <span className={`live-dot ${stale ? 'stale' : ''}`} />
            {stale ? 'data stale — fetch failing' : `data ${relTime(data.generated_at)}`}
          </span>
          <span>
            cycle <b>{cycle.start_date} → {cycle.end_date}</b>
          </span>
          <span>
            day <b>{cycle.elapsed_days}/{cycle.cycle_days}</b> · {cycle.left_days} left
          </span>
          <span>
            {refresh.enabled
              ? `backend refresh every ${refresh.interval_minutes}m`
              : 'static snapshot'}
          </span>
        </div>
      </header>

      <div className="cycle-bar" title={`cycle ${cyclePct.toFixed(0)}% elapsed`}>
        <div className="cycle-bar-fill" style={{ width: `${cyclePct}%` }} />
      </div>

      {stale && (
        <div className="stale-banner">
          Showing the last good snapshot — background fetch of data.json is failing ({error}).
        </div>
      )}

      <div className="cards">
        <div className="card accent">
          <div className="card-label">Consumed ACUs</div>
          <div className="card-value">{fmt(ent.consumed)}</div>
          <div className="card-sub">{burnPct.toFixed(1)}% of pool</div>
        </div>
        <div className={`card ${ent.remaining < 0 ? 'bad' : ''}`}>
          <div className="card-label">Remaining of {fmt(data.pool)}</div>
          <div className={`card-value ${ent.remaining < 0 ? 'bad' : ''}`}>{fmt(ent.remaining)}</div>
        </div>
        <div className="card">
          <div className="card-label">Daily run rate</div>
          <div className="card-value">{fmt(ent.daily_run_rate)}</div>
          <div className="card-sub">ACUs / day</div>
        </div>
        <div className="card">
          <div className="card-label">Projected cycle-end</div>
          <div className="card-value">{fmt(ent.projected_cycle_total)}</div>
          <div className="card-sub">
            {ent.projected_over_under >= 0 ? 'under by ' : 'over by '}
            {fmt(Math.abs(ent.projected_over_under))}
          </div>
        </div>
        <div className={`card ${ent.verdict === 'OVER' ? 'bad' : 'good'}`}>
          <div className="card-label">Verdict</div>
          <div className={`card-value ${ent.verdict === 'OVER' ? 'bad' : 'good'}`}>{ent.verdict}</div>
        </div>
      </div>

      <div className="panel-grid">
        <section className="panel">
          <h2 className="panel-title">Burn rate</h2>
          <BurnChart
            daily={data.daily}
            cycle={cycle}
            pool={data.pool}
            runRate={ent.daily_run_rate}
            projected={ent.projected_cycle_total}
          />
        </section>
        <section className="panel">
          <h2 className="panel-title">Product split</h2>
          <ProductSplitPanel split={data.product_split} />
        </section>
      </div>

      <section className="panel">
        <h2 className="panel-title">Warnings</h2>
        <ul className="warnings">
          {data.warnings.length === 0 ? (
            <li className="empty">None — every org and user within cap and forecast.</li>
          ) : (
            data.warnings.map((w) => <li key={w}>{w}</li>)
          )}
        </ul>
      </section>

      <OrgTable orgs={data.orgs} />
      <UserTable users={data.users} />

      <footer>
        generated {data.generated_at} · local-only console · data via Devin v3 API (read-only) ·
        regenerate: <code>dag dashboard</code>
      </footer>
    </>
  )
}
