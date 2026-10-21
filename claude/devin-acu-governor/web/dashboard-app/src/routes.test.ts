import { describe, expect, test } from 'vitest'
import { parseRoute } from './routes'

describe('parseRoute', () => {
  test('defaults to overview', () => {
    expect(parseRoute('')).toEqual({ page: 'overview' })
    expect(parseRoute('#')).toEqual({ page: 'overview' })
    expect(parseRoute('#/')).toEqual({ page: 'overview' })
    expect(parseRoute('#/nonsense')).toEqual({ page: 'overview' })
  })

  test('top-level pages', () => {
    expect(parseRoute('#/orgs')).toEqual({ page: 'orgs' })
    expect(parseRoute('#/users')).toEqual({ page: 'users' })
    expect(parseRoute('#/last-month')).toEqual({ page: 'last-month' })
  })

  test('agent output tabs, with the legacy anchor and unknown tabs folded to overview', () => {
    expect(parseRoute('#/output')).toEqual({ page: 'output', tab: 'overview' })
    expect(parseRoute('#agent-output')).toEqual({ page: 'output', tab: 'overview' })
    expect(parseRoute('#/output/daily')).toEqual({ page: 'output', tab: 'daily' })
    expect(parseRoute('#/output/splits')).toEqual({ page: 'output', tab: 'splits' })
    expect(parseRoute('#/output/members')).toEqual({ page: 'output', tab: 'members' })
    expect(parseRoute('#/output/bogus')).toEqual({ page: 'output', tab: 'overview' })
  })

  test('per-org page decodes the org id', () => {
    expect(parseRoute('#/org/platform')).toEqual({ page: 'org', orgId: 'platform' })
    expect(parseRoute('#/org/org%20with%20space')).toEqual({ page: 'org', orgId: 'org with space' })
  })
})
