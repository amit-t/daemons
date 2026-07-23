## Task: explain what the target Claude agent is doing

Answer the user's question (see run context). If none was given, default to:
"what is this agent currently doing, and what has it done recently?"

### Steps

1. **Confirm the target is alive.** Check the pid from the run context is still running
   (`ps -o pid=,lstart=,command= -p <pid>`). If it exited, say so and pivot to the
   transcript as a historical record.
2. **Read the transcript.** Open the JSONL path from the run context. Establish:
   - the current / most recent task the agent is working on (last user instruction +
     what the assistant is doing about it);
   - the last few tool calls (`tool_use` blocks) — these reveal live activity
     (editing files, running commands, searching);
   - whether it looks **active** (recent timestamps, mid-tool-call) or **idle / waiting**
     (last event is an assistant message awaiting user input) or **stuck / errored**.
3. **Corroborate with the working tree** when a cwd is known and it helps: read-only
   `git -C <cwd> status` / `git -C <cwd> log --oneline -5` to see uncommitted work in
   flight. Do not change anything.
4. **Report token/usage weight** from `.message.usage` totals so the user knows roughly
   how much this session has consumed.

### Output

Lead with a one-line answer: **what the agent is doing right now**. Then:

- **Task** — the goal in one or two lines.
- **Recent activity** — last 3–6 concrete actions (tool calls / edits / commands), newest first.
- **State** — active / idle-waiting / stuck, with the evidence (last timestamp, last event type).
- **Location & session** — cwd, session-id, transcript path.
- **Usage** — rough token totals for the session.

Keep it tight. Offer a follow-up only if the user asked something you could not resolve
read-only (e.g. "want me to attach to it / tail it live?"). Never take a mutating action
without an explicit new instruction.
