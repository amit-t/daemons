import { useEffect, useState } from 'react'

// Hash-based routing so the static snapshot stays servable from a plain file
// server and every page survives reload / can be bookmarked.
//   #/            -> overview (also '' and '#')
//   #/orgs        -> organizations page
//   #/users       -> users page
//   #/output      -> agent output, sub-tabs #/output/<tab>
//   #/last-month  -> previous-cycle usage comparison
//   #/org/<id>    -> per-org detail page
//   #agent-output -> legacy jump link, now the output page
export type OutputTab = 'overview' | 'daily' | 'splits' | 'members'

export type Route =
  | { page: 'overview' }
  | { page: 'orgs' }
  | { page: 'users' }
  | { page: 'output'; tab: OutputTab }
  | { page: 'last-month' }
  | { page: 'org'; orgId: string }

const OUTPUT_TABS: OutputTab[] = ['overview', 'daily', 'splits', 'members']

export function parseRoute(hash: string): Route {
  const org = hash.match(/^#\/org\/(.+)$/)
  if (org) return { page: 'org', orgId: decodeURIComponent(org[1]) }
  if (hash === '#/orgs') return { page: 'orgs' }
  if (hash === '#/users') return { page: 'users' }
  if (hash === '#/last-month') return { page: 'last-month' }
  if (hash === '#agent-output' || hash === '#/output') return { page: 'output', tab: 'overview' }
  const output = hash.match(/^#\/output\/(.+)$/)
  if (output) {
    const tab = output[1] as OutputTab
    return { page: 'output', tab: OUTPUT_TABS.includes(tab) ? tab : 'overview' }
  }
  return { page: 'overview' }
}

export function useRoute(): Route {
  const [hash, setHash] = useState(() => window.location.hash)
  useEffect(() => {
    const onChange = () => setHash(window.location.hash)
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])
  return parseRoute(hash)
}
