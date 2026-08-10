import { useEffect, useState } from 'react'
import { useDashboardData } from './useDashboardData'
import { fmt } from './format'
import { BurnChart } from './components/BurnChart'
import { UserSplitPanel } from './components/UserSplit'
import { OrgTable } from './components/OrgTable'
import { OrgDetail } from './components/OrgDetail'
import { UserTable } from './components/UserTable'
import { UserDetail } from './components/UserDetail'
import { RefreshControls } from './components/RefreshControls'

// "#/org/<org_id>" routes to the per-org page; anything else is the console.
// Hash-based so the static snapshot stays servable from a plain file server
// and the page survives reload / can be bookmarked.
function useOrgRoute(): string | null {
  const [hash, setHash] = useState(() => window.location.hash)
  useEffect(() => {
    const onChange = () => setHash(window.location.hash)
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])
  const m = hash.match(/^#\/org\/(.+)$/)
  return m ? decodeURIComponent(m[1]) : null
}

export default function App() {
  const { data, error, stale, status, manualRefreshing, refreshNow } = useDashboardData()
  // Selection is by id, not row object, so a background refresh swaps in the
  // freshly fetched row while the drawer stays open.
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null)
  const orgRouteId = useOrgRoute()

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
  const selectedUser = selectedUserId
    ? (data.users.find((u) => u.user_id === selectedUserId) ?? null)
    : null
  const selectedOrg = orgRouteId ? (data.orgs.find((o) => o.org_id === orgRouteId) ?? null) : null
  const cyclePct = Math.min(100, (cycle.elapsed_days / cycle.cycle_days) * 100)
  const burnPct = data.pool > 0 ? Math.min(100, (ent.consumed / data.pool) * 100) : 0
  const capTotals = data.cap_totals

  return (
    <>
      <header className="console-header">
        <h1 className="console-title">
          DAG <span className="dim">// ACU BURN CONSOLE</span>
        </h1>
        <RefreshControls
          status={status}
          stale={stale}
          generatedAt={data.generated_at}
          cycle={cycle}
          refresh={refresh}
          manualRefreshing={manualRefreshing}
          onRefresh={refreshNow}
        />
      </header>

      <div className="cycle-bar" title={`cycle ${cyclePct.toFixed(0)}% elapsed`}>
        <div className="cycle-bar-fill" style={{ width: `${cyclePct}%` }} />
      </div>

      {stale && (
        <div className="stale-banner">
          Showing the last good snapshot — background fetch of data.json is failing ({error}).
        </div>
      )}

      {orgRouteId ? (
        selectedOrg ? (
          <OrgDetail
            org={selectedOrg}
            users={data.users}
            cycle={cycle}
            cloudSessions={data.cloud_sessions}
            modelAnalytics={data.model_analytics}
            onBack={() => {
              window.location.hash = ''
            }}
            onSelectUser={(u) => setSelectedUserId(u.user_id)}
          />
        ) : (
          <div className="boot">
            <p className="boot-error">
              org {orgRouteId} is not in this snapshot — <a href="#">back to console</a>
            </p>
          </div>
        )
      ) : (
        <>
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
            <div className="card accent">
              <div className="card-label">Capped user total</div>
              <div className="card-value">{fmt(data.cap_totals.effective_user_cycle_acu_limit)}</div>
              <div className="card-sub">
                if {capTotals.capped_users} capped user{capTotals.capped_users === 1 ? '' : 's'} use full cap
                {capTotals.uncapped_users > 0 ? ` · ${capTotals.uncapped_users} uncapped` : ''}
              </div>
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
              <BurnChart daily={data.daily} cycle={cycle} />
            </section>
            <section className="panel">
              <h2 className="panel-title">User split</h2>
              <UserSplitPanel users={data.users} />
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
    
          <OrgTable
            orgs={data.orgs}
            onSelect={(o) => {
              window.location.hash = `#/org/${encodeURIComponent(o.org_id)}`
            }}
          />
          {data.attribution && data.attribution.unattributed > 0 && (
            <div className="attribution-note">
              {fmt(data.attribution.unattributed)} ACUs this cycle are attributed to no organization (users without
              billing_org_id) — org caps cannot gate that usage.
            </div>
          )}
          <UserTable users={data.users} onSelect={(u) => setSelectedUserId(u.user_id)} />
        </>
      )}

      {selectedUser && (
        <UserDetail
          user={selectedUser}
          cycle={cycle}
          modelAnalytics={data.model_analytics}
          onClose={() => setSelectedUserId(null)}
        />
      )}

      <footer>
        generated {data.generated_at} · local-only console · data via Devin v3 API (read-only) ·
        regenerate: <code>dag dashboard</code>
      </footer>
    </>
  )
}
