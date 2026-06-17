# AICC Default Kid-Panel Goal Orchestration Design

## Goal

AICC base orchestrators should attempt to decompose ordinary user tasks across enabled `kid-*` panels even when Amit does not explicitly say “distribute” or “orchestrate,” and every delegated kid-panel prompt must tell that panel to mark the assigned work as a goal.

## Current behavior

AICC already creates enabled managed side panes (`kid-claude`, `kid-codex`, optional `kid-devin`) and injects a base orchestrator prompt from `codex/ai-cmux-conductor/src/ai-cmux-conductor/conductor.ts`. Existing prompt rules strongly route requests that explicitly name kid panes, but ordinary tasks may be handled in the base orchestrator or backgrounded.

## Design

Use a prompt-only behavior change in `buildOrchestratorPrompt`. Add a “default orchestration” rule for sessions with at least one enabled kid panel:

- For every non-trivial user task, first consider whether independent parts can run in parallel on enabled kid panels.
- Delegate suitable chunks to enabled `kid-*` panes by sending refined, self-contained prompts through cMUX.
- Keep the base orchestrator responsible for task breakdown, routing, progress checks, integration, and final response.
- Skip delegation only for trivial single-step requests, sensitive/unsafe actions, tasks requiring user clarification before any work can begin, or tasks where parallel work would be counterproductive.
- Explicit kid-pane routing still wins: if Amit names a kid pane, route there exactly as requested.

Each delegated prompt must include a goal instruction:

- “Mark this assignment as a goal before working.”
- A concrete objective.
- Context and constraints.
- Acceptance criteria.
- Verification commands/evidence required.
- Report-back format for the base orchestrator.

When no managed side-agent panels are enabled, prompt stays honest: the base orchestrator does work itself unless Amit changes feature flags and restarts AICC.

## Files

- Modify `codex/ai-cmux-conductor/src/ai-cmux-conductor/conductor.ts` to extend prompt text.
- Modify `codex/ai-cmux-conductor/test/ai-cmux-conductor-panels.test.ts` with failing prompt assertions before implementation.
- Modify `codex/ai-cmux-conductor/README.md` and root `README.md` to document behavior.

## Testing

- Add Bun tests asserting default orchestration and goal-marking prompt content appears when kid panes are enabled.
- Assert no default orchestration section appears when all side panels are disabled.
- Run full `bun test`, `bun run typecheck`, and `zsh -n` on zsh entrypoints/wrappers.

## Non-goals

- No daemon-level automatic dispatch without orchestrator judgment.
- No feature flag for this behavior; user requested default “whenever” behavior.
- No changes to panel creation defaults.
