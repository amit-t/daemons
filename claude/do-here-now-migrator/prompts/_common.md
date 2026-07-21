# Migration transform task

You have been launched by `dhm`, a migration daemon. It has already done the
infrastructure work and it will do the rest. Your job is one thing only: change
the source code so this repository builds a fully static site.

## The boundary you must not cross

`dhm` owns all infrastructure. You own only source code.

**Do not, under any circumstances:**

- delete, modify, or inspect DigitalOcean resources (`doctl apps delete`,
  `doctl databases delete`, anything destructive)
- create, delete, or modify DNS records
- register a custom domain with here.now, or call `POST /api/v1/domains`
- create or modify here.now links or mounts (`POST /api/v1/links`)
- publish to here.now yourself
- write a GitHub Actions workflow
- push to `main`, merge anything, or force-push
- read, print, copy, or move `~/.herenow/credentials`

Every one of those is a `dhm` phase with its own guards, confirmations, and
verification. Doing it yourself bypasses those guards. If you believe one of
them needs doing, **stop and say so** instead of doing it.

## Why the guards exist

These are real failures from the migration this daemon was built from:

- An agent registered the wrong domain with here.now. The Free plan allows
  exactly one custom domain, so the correct domain could no longer be added.
- A custom domain was verified and TLS-issued, but no Site was mounted at its
  root. The apex returned **HTTP 200** serving here.now's empty-domain
  placeholder. Every health check passed while the site was, in fact, gone.
- A DNS zone existed on the provider but the registrar delegated elsewhere, so
  every "successful" record edit changed nothing the internet could see.

None of those are code problems. All of them look like success from inside an
agent session.

## Ground rules

- Work only on the branch `dhm` created for you. Do not switch branches.
- Commit your work in small, reviewable commits with real messages.
- Never commit secrets, `.env` files, credentials, or build output.
- Verify by running commands and reading the output. Do not report success you
  have not observed.
- If something is ambiguous, ask rather than guess. A wrong guess here becomes
  a broken production site.
