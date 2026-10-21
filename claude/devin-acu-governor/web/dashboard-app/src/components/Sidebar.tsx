import type { Route } from '../routes'

interface NavItem {
  hash: string
  label: string
  page: Route['page']
  count?: number
}

// Left-side navigation. The per-org detail page highlights Organizations;
// collapses to a horizontal strip on narrow screens (see .layout-side CSS).
export function Sidebar({ route, orgCount, userCount }: { route: Route; orgCount: number; userCount: number }) {
  const items: NavItem[] = [
    { hash: '#/', label: 'Overview', page: 'overview' },
    { hash: '#/orgs', label: 'Organizations', page: 'orgs', count: orgCount },
    { hash: '#/users', label: 'Users', page: 'users', count: userCount },
    { hash: '#/output', label: 'Agent output', page: 'output' },
    { hash: '#/last-month', label: 'Last month', page: 'last-month' },
  ]
  const activePage = route.page === 'org' ? 'orgs' : route.page
  return (
    <nav className="side-nav" aria-label="Dashboard sections">
      {items.map((item) => (
        <a
          key={item.page}
          href={item.hash}
          className={`side-nav-item${activePage === item.page ? ' on' : ''}`}
          aria-current={activePage === item.page ? 'page' : undefined}
        >
          <span>{item.label}</span>
          {item.count != null && <span className="side-nav-count">{item.count}</span>}
        </a>
      ))}
    </nav>
  )
}
