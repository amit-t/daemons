# devin-acu-governor (`dag`) Implementation Plan

> Historical plan updated 2026-06-11 after Cognizant supplied the Local Agent ACU-limit API. Implementation is complete in `claude/devin-acu-governor/`; this document now records the finished scope and verification checklist.

**Goal:** `dag` enforces Devin Local Agent ACU governance by prorating remaining ACUs across engineers, setting per-user Local Agent limits, supporting Boost/Borrow reallocations, and providing a local org-level global limit command with live verification.

**Architecture:** zsh launcher + Claude playbooks for interactive workflows; local zsh commands for `doctor`, `dashboard`, and `set limit global`; jq for all cap math.

## Implemented tasks

- [x] Update API contract from stale Windsurf credit endpoints to Devin `v3beta1` ACU-limit endpoints.
- [x] Preserve `user_id` through `compute-caps.jq` so set-limits can PATCH `/v3beta1/enterprise/users/{user_id}/consumption/acu-limits`.
- [x] Update `set-limits` playbook to discover user IDs, prorate remaining ACUs, PATCH each user override, and GET verify each write.
- [x] Update `boost` playbook to Boost + Borrow with live user-limit reads, PATCH recipient/donors, and GET verify every changed user.
- [x] Add local `dag set limit global <acus> [org_id|org_name]` plus aliases; implement org discovery, PATCH org Local Agent limit, GET verification, and UI instructions.
- [x] Update `doctor` to probe `ViewAccountConsumption`/`ManageBilling` via v3beta1 ACU-limit read/write endpoints.
- [x] Update `user`/`status` playbooks to report explicit/default/effective Local Agent limits.
- [x] Harden dashboard read-only/error behavior and keep local dashboard deterministic.
- [x] Update README, root README summary, and design doc.
- [x] Verify with full zsh test suite and zsh parse checks.

## Verification commands

```zsh
zsh claude/devin-acu-governor/test/run.zsh
zsh -n claude/devin-acu-governor/bin/dag
zsh -n claude/devin-acu-governor/lib/*.zsh
```
