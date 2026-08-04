# hivemind sync playbook

Goal: converge this machine and the other machine(s) onto one identical set of global agent instructions/memories, via the `agent-sync/` ledger in the Profiles repo.

Use `zsh <daemon-dir>/bin/hive <command>` for every engine call (daemon dir is in Run context).

## Steps

1. `cd` into the profiles dir (Run context). Non-negotiable, even if launched elsewhere.
2. `hive snapshot` — pulls the repo, captures this machine's live surfaces into `agent-sync/machines/<host>/`, commits, pushes. This publishes "this is my timeline now".
3. `hive plan` — parse the `action=` line and branch:

### action=NEED_OTHER_MACHINE
Only this host has ever snapshotted. Tell Amit: run `hive` on the other machine (the daemons + Profiles repos are synced there), then run `hive` here again. Stop.

### action=STALE_OTHER
The other machine's snapshot is older than the freshness window (see `stale_hosts=` and per-host `age_hours=`). Ask Amit — exactly this decision, use AskUserQuestion when available:
- **Refresh first (recommended):** Amit runs `hive` on the stale machine, then re-runs `hive` here. Stop after reporting.
- **Reconcile anyway:** re-run `hive plan` with `HIVE_FORCE=1` and continue as RECONCILE below, flagging that the other side's data is N hours old.

### action=APPLY_GOLDEN
A reconciled golden set exists that this host hasn't applied. This is the convergence path — do NOT re-ask for a decision that was already made on the other machine.
1. `hive diff --golden` to see what will change locally (may be empty for identical files).
2. `hive apply` — overwrites live surfaces from golden, backs up everything first, marks this host applied, re-snapshots, pushes.
3. Report: files overwritten, files removed, backup path, and that both machines are now converged (confirm with `hive status`).

### action=IN_SYNC
Report `hive status` output: hosts, ages, "IN SYNC". Done.

### action=RECONCILE
Both snapshots fresh, content diverged. This is your judgment work:

1. Read both machine trees under `agent-sync/machines/` (manifests + files) and `hive diff` output.
2. Build a reconciliation report for Amit, grouped per surface:
   - **Identical on both** — count only.
   - **Diverged (same file, different content)** — show the meaningful delta; recommend which version wins or a merge. Judge by: newer `mtime` in the manifests, more specific/complete content, and whether one side merely lags the other.
   - **Only on machine A / only on machine B** — recommend add-to-both or drop. A file that exists on one side is usually a memory the other machine never learned → default add; recommend drop only for stale/duplicated/superseded content.
   - **Duplicates within a surface** (e.g. five near-identical `*zsh-preference*.md` memories) — recommend consolidating into one canonical file and dropping the rest.
3. Present the full plan (adds, removes, merges, winners) and get Amit's approval. AskUserQuestion with option to approve as-is, edit, or abort.
4. On approval:
   - `hive golden init --from <host>` — seed from the host closer to the desired end state.
   - Edit files under `agent-sync/golden/` to realize the approved plan (add the other machine's files, write merged/deduped content, delete dropped files). Golden must contain exactly the approved end state — `apply` removes live `dir-md` files that are absent from golden.
   - `hive golden finalize --hosts <A,B>` — stamps manifest + state, pushes.
   - `hive apply` — converges THIS machine immediately.
5. Report: the decided golden summary, this machine's apply result + backup path, and the single remaining step: run `hive` on the other machine — it will hit APPLY_GOLDEN and converge without questions.

## Always end with
`hive status` output so Amit sees host ages, golden state, and sync verdict at a glance.
