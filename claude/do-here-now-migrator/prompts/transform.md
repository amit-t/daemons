---

# Your task

Convert this repository into a fully static site.

## Context

| | |
| --- | --- |
| Repository | `{{REPO}}` |
| Branch (already checked out) | `{{BRANCH}}` |
| Migration state key | `{{SITE}}` |
| Target domain | `{{DOMAIN}}` |
| Framework | `{{FRAMEWORK}}` |
| Package manager | `{{PACKAGE_MANAGER}}` |
| Required static output directory | `{{OUTPUT_DIR}}` |
| Install command | `{{INSTALL_COMMAND}}` |
| Build command | `{{BUILD_COMMAND}}` |

### How this framework goes static

{{STATIC_RECIPE}}

### Server-side coupling detected

These block a static export. Each must be removed, replaced, or proven unused:

{{SERVER_COUPLING}}

### Files that mention subscribe/newsletter

{{SUBSCRIBE_CANDIDATES}}

### Subscribe replacement decided by the operator

| | |
| --- | --- |
| Provider | `{{SUBSCRIBE_PROVIDER}}` |
| URL | `{{SUBSCRIBE_URL}}` |

---

## Step 1 — Understand before you change

Read the code the detection flagged. Confirm what each piece of server-side
coupling actually does at runtime. Detection is a heuristic; a dependency in
`package.json` may be dead code, and a directory named `api` may be static
fixtures.

Produce, for yourself, a list of every runtime behaviour that will not survive
a static export. Typical examples:

- form POST handlers (subscribe, contact, comments)
- authentication and session routes
- admin dashboards backed by a database
- server-rendered pages that read a database at request time
- image optimisation endpoints
- middleware, redirects, and rewrites evaluated on the server
- cron/scheduled jobs and webhooks

If any of these is load-bearing for the site's purpose and cannot be replaced
by a hosted third party, **stop and report that** — a static migration would
silently drop it.

## Step 2 — Make the framework emit static output

Apply the recipe above. The build must write a real static site to
`{{OUTPUT_DIR}}`, including an `index.html` at its root.

Content that came from a database at request time has to come from somewhere
else. In order of preference:

1. Content already in the repository (Markdown, MDX, JSON, YAML).
2. Content exported from the database into the repository as data files. The
   database dump is in the backup directory `dhm` created; ask the operator for
   its path rather than reconnecting to a live database.
3. Content fetched at **build** time from an API that will still exist.

Never leave a runtime fetch to a service that is about to be destroyed.

## Step 3 — Replace the subscribe form

A static site has no runtime, so a form that POSTs to your own backend cannot
work. It must not be left in place looking functional.

**If the provider is `none`:** remove the form and its handler entirely. Do not
leave a disabled input, and do not add a replacement CTA.

**Otherwise:** replace the form with a plain, clearly-labelled link to
`{{SUBSCRIBE_URL}}`, styled to match the surrounding design.

Requirements either way:

- Delete the client-side submit handler, its state, and its API call.
- Delete the corresponding server route or handler.
- Put the URL in the site's central config module if one exists, not inline in
  a component. It changes independently of markup.
- External link hygiene: `rel="noopener noreferrer"`, and `target="_blank"`
  only if the rest of the site does that for external links.
- Remove now-unused dependencies (mailer clients, validation schemas, database
  models used only by the form) and their environment variables.
- Update any test that asserted the old form's behaviour. Do not delete a test
  to make a suite pass — rewrite it to assert the new behaviour.

Do not assume the provider has any API, account, or list already configured.
You are adding a link, nothing more. Do not attempt to import subscribers, call
a provider API, or authenticate anywhere.

## Step 4 — Remove what the static site cannot use

- Server frameworks, database drivers, ORMs, and session libraries that are now
  unreferenced.
- `Dockerfile`, `docker-compose*.yml`, `Procfile`, and deployment scripts that
  only existed for the old host.
- Documentation describing the retired deployment. Replace it, do not just
  delete it — a README that still explains a dead deploy is worse than none.
- Environment variables that no longer have a consumer, in `.env.example` and
  in the docs.

Leave anything you are unsure about, and list it in your final report.

## Step 5 — Prove it builds

```
{{INSTALL_COMMAND}}
{{BUILD_COMMAND}}
```

Then confirm, by actually running these and reading the output:

- `{{OUTPUT_DIR}}/index.html` exists.
- Every route that existed before has a corresponding `index.html` in
  `{{OUTPUT_DIR}}`. Compare against the site's previous route list. A route that
  silently disappears is the most common defect in this kind of migration.
- No `.env`, `.env.local`, or `node_modules` was copied into `{{OUTPUT_DIR}}`.
- No connection string, API key, or private key appears anywhere under
  `{{OUTPUT_DIR}}`. Grep for it. Anything in that directory becomes public.

Serve `{{OUTPUT_DIR}}` locally and click through it. A build that exits zero and
produces a blank page still exits zero.

If the repository has an end-to-end suite, point it at the local static server
and make it pass. `next start` and equivalents do not work with a static export,
so the suite must target a plain file server.

## Step 6 — Update the documentation

Rewrite whatever describes how this site is built and deployed, so it matches
reality: static export, published to here.now, deployed on push to `main`.

Do not document the here.now slug, domain binding, or CI secrets — `dhm` owns
those and writes `docs/migration-to-here-now.md` itself.

## Step 7 — Commit, then hand back

Commit your work on `{{BRANCH}}`. Do not push, do not merge, do not touch
`main`.

Then hand control back to the daemon:

```
dhm continue --site {{SITE}}
```

That resumes the pipeline: build, publish to here.now, DNS cutover, domain
binding, production verification, and CI wiring. Decommissioning the old
infrastructure stays a separate, explicitly-confirmed command.

## Final report

State plainly:

1. What you changed, by file.
2. Every runtime behaviour that was removed and not replaced.
3. The route list before and after, and any route that no longer exists.
4. Build and test results, with the actual numbers you observed.
5. Anything you left alone because you were unsure.

Report failures as failures. A migration that quietly drops a feature is worse
than one that stops and asks.
