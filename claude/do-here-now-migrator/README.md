# do-here-now-migrator (`dhm`)

Migrates a site off DigitalOcean App Platform: converts it to a static site,
publishes it to here.now, cuts DNS over, wires push-to-deploy, and only then
removes the DigitalOcean resources it can positively attribute to that site.

Run it against any repository. Nothing about the target site is hard-coded.

## The design decision that matters

**Deterministic zsh owns infrastructure. An AI agent owns only source code.**

| Owned by `dhm` | Owned by the agent |
| --- | --- |
| Resource discovery and attribution | Framework configuration for static export |
| Database dumps and archives | Removing server-side coupling |
| DNS record changes | Replacing the subscribe form |
| here.now domains, mounts, publishing | Route and content migration |
| GitHub Actions and repository secrets | Documentation of the build |
| Destroying anything | — |

An agent is the only thing that can rewrite a Next.js app into a static export.
An agent is also perfectly capable of deleting the wrong database or pointing a
domain at the wrong site, and it will report success either way. So the parts
that can lose data are not delegated.

This split comes from a real migration, where the agent:

- registered the wrong domain with here.now, consuming the Free plan's single
  custom-domain slot so the correct domain could no longer be added;
- left a verified domain with no Site mounted at its root, so the apex returned
  **HTTP 200** serving here.now's empty-domain placeholder while every health
  check passed and the site was, in fact, gone;
- edited a DNS zone that the registrar did not delegate to, so every
  "successful" record change was invisible to the internet.

`dhm` checks for all three, deterministically, every run.

## Usage

```zsh
dhm run --domain example.com --subscribe substack --subscribe-handle myblog
```

Pick the agent that does the transform:

```zsh
dhm run --claude  --domain example.com    # `co`     (default)
dhm run --cf      --domain example.com    # `cf`
dhm run --codex   --domain example.com    # `cxscb`
dhm run --devin   --domain example.com    # `dey`
```

`--agent claude|cf|codex|devin` is equivalent, and the raw command names
(`co`, `cf`, `cxscb`, `dey`) are accepted too.

Look before you leap:

```zsh
dhm plan --domain example.com      # preflight + inventory, changes nothing
dhm run  --domain example.com --dry-run
dhm doctor                         # tools, credentials, launchers
```

## How a migration runs

`dhm run` executes phases in order, from the first incomplete one. State lives
in `~/.local/state/do-here-now-migrator/<site>/state.json`, so an interrupted
migration resumes where it stopped.

| Phase | What it does | Destructive |
| --- | --- | --- |
| `preflight` | Tools, credentials, repo hygiene, framework detection | no |
| `inventory` | Read-only DigitalOcean discovery and attribution | no |
| `backup` | Dump databases, archive app specs, snapshot DNS | no |
| `account` | Ensure a here.now account and API key exist | no |
| `transform` | Hand the source transformation to the chosen agent | no |
| `build` | Install, build, prove the export is real and secret-free | no |
| `publish` | Publish the export to here.now | no |
| `domain` | Register the domain, apply DNS, mount the Site at its root | DNS only |
| `verify` | Full production gate | no |
| `ci` | Write the deploy workflow, set the repo secret and variable | no |
| `decommission` | Remove the attributed DigitalOcean resources | **yes** |
| `report` | Write `docs/migration-to-here-now.md` | no |

The `transform` phase replaces the process with an agent session, exactly like
`dag`. The agent's prompt ends by telling it to run `dhm continue`, which
resumes the pipeline.

`--through` defaults to `ci`, so **`dhm run` never destroys anything**.
Decommissioning is always a separate, explicit command:

```zsh
dhm decommission --site example-site
```

## Safety model

1. **DNS.** Only apex and `www` records of type `A`, `AAAA`, or `CNAME` are
   ever created or deleted. `MX`, `TXT`, `SPF`, `DKIM`, `DMARC`, `CAA`, `SRV`,
   `NS`, `SOA`, and every unrelated subdomain are preserved. There is a guard
   immediately before each deletion, not only at the planning stage. CNAME
   targets are normalized to the fully qualified trailing-dot form required by
   DigitalOcean before creation.
2. **Attribution.** A DigitalOcean resource is destroyed only when its App spec
   names the repository being migrated or a domain being migrated. A database is
   claimed only when a claimed App references it. Everything else is listed as
   untouched and left alone. Substring matches do not count.
3. **Backups first.** Nothing is destroyed until a backup has been written *and
   read back* — document counts for Mongo, non-empty dumps for SQL engines.
4. **Verify before destroy.** Decommission refuses to run until the `verify`
   phase has passed. `--decommission-first` overrides this and says plainly that
   the site will be offline until the replacement is live.
5. **Typed confirmation.** Destroying a resource requires typing its exact name.
   `--yes` does not bypass the backup precondition.
6. **Non-interactive refusal.** A confirmation prompt with no terminal attached
   is a refusal, not an approval.
7. **Secrets.** The here.now API key is read at the point of use, never logged,
   never written to state, never passed on a command line. Archived App specs
   are written `0600` and flagged as secret-bearing. Log output is passed
   through a redactor.

## Verification, and the failure it exists to catch

A here.now custom domain that is verified but has no Site mounted returns
**HTTP 200** serving a placeholder page. A route check, a TLS check, and an
uptime monitor all pass while the site is not being served at all.

So the authoritative test is not "does the apex return 200" but **"does the apex
return the same bytes as the published Site"**. `dhm verify` compares SHA-256
hashes of both homepages. The generated CI workflow does the same with `cmp`.

`dhm verify` also checks: TLS validity, the root mount reported by the custom
domain API, every route derived from the built output, the `www` redirect, the
subscribe CTA, and that the retired origin is no longer referenced.
For apex domains, the domain phase waits for both the apex and here.now's
automatically paired `www` domain to report active TLS before verification.

## Subscribe replacement

A static site has no runtime, so a form that POSTs to your own backend cannot
work and must not be left looking functional.

`--subscribe` accepts `substack`, `buttondown`, `convertkit`, `mailchimp`,
`beehiiv`, `ghost`, `custom`, or `none`. Substack is a suggestion, never an
assumption.

- Supply `--subscribe-url`, or `--subscribe-handle` to derive it.
- The URL is probed before the agent wires it in, so a typo fails early.
- HTTP URLs are rejected; a subscribe link is where users type an email address.
- No provider API is ever called and no account is assumed. `dhm` adds a link.
- With no provider and no terminal, the answer is `none`. Guessing a URL and
  shipping it as a working button is worse than shipping no button.

If a database held subscribers, the backup phase writes
`subscribers-import.csv` in the `email,name,created_at` shape every mainstream
platform imports.

## here.now accounts

No account is assumed. If `~/.herenow/credentials` is missing, `dhm account`
runs the email one-time-code flow, which also creates the account, and stores
the key at mode `600`.

An **anonymous publish is a hard failure**, never a fallback: an anonymous Site
expires in 24 hours, so accepting one would hand back a link that dies
overnight.

`dhm` checks the apex-domain count before registering a domain, because the
Free plan allows exactly one and the API error is otherwise opaque.

## Files

```
bin/dhm                          CLI and phase orchestration
lib/common.zsh                   logging, state, confirmation, redaction
lib/preflight.zsh                tool, credential, and repository checks
lib/detect.zsh                   framework, package manager, server coupling
lib/inventory.zsh                DigitalOcean discovery and attribution
lib/backup.zsh                   database dumps, spec archives, DNS snapshots
lib/herenow.zsh                  account, publishing, domains, root mounts
lib/dns.zsh                      DNS cutover and the record allowlist
lib/subscribe.zsh                subscribe provider resolution
lib/transform.zsh                agent selection, prompt rendering, launch
lib/build.zsh                    build execution and export validation
lib/verify.zsh                   the production gate
lib/ci.zsh                       workflow generation and repo settings
lib/decommission.zsh             the destructive phase and its guards
lib/report.zsh                   status output and the migration record
prompts/_common.md               the boundary the agent must not cross
prompts/transform.md             the transform playbook
templates/deploy-here-now.yml    generated GitHub Actions workflow
test/                            zsh test suite with fixtures, no network
environment.env                  defaults; shell environment overrides
```

## Verification

```zsh
zsh claude/do-here-now-migrator/test/run.zsh
```

293 assertions across 10 files, all offline. Coverage focuses on the parts where
a defect costs data: the DNS allowlist, resource attribution, export validation,
custom-domain state, the destructive-phase preconditions, and agent selection.

Parse-check after any edit:

```zsh
for f in claude/do-here-now-migrator/bin/dhm claude/do-here-now-migrator/lib/*.zsh; do zsh -n "$f"; done
```

## Known limits

- The here.now Free plan allows **one** custom domain. DNS cannot HTTP-redirect
  one domain to another, so serving a second domain needs a paid plan or a
  redirect-capable host.
- DigitalOcean is the only DNS provider `dhm` edits automatically. Others get
  printed instructions.
- A static site has no runtime. Auth, form POSTs, scheduled jobs, and API routes
  are removed, not moved. The transform prompt requires the agent to report
  every behaviour it dropped.
- App Platform pre/post-deploy jobs have no equivalent and are not migrated;
  `dhm ci` says so explicitly.
