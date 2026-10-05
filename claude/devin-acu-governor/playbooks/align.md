# Playbook: align (per-user ACU routing alignment)

Read-only routing audit of one user against the ACU routing deck. No confirmation gates, nothing written, no API mutations. Target email is in Run context (`align target`). The deck is inlined below under "## ACU routing deck"; if Run context says the deck is ABSENT, stop after the usage report and say the deck path (`DAG_ROUTING_DECK`) must point at a readable routing policy file.

The deliverable is a verdict plus, when misrouted, one short email the operator pastes into Outlook unchanged.

## Steps

1. **Cycle.** GET `/v3/enterprise/consumption/cycles` → current cycle epochs.
2. **Resolve the user.** GET `/v3/enterprise/members/users` (paginate) → this email's `user_id` and `name`. Stop with a clear message if the email is not in the roster.
3. **Their cycle ACUs.** GET `/v3/enterprise/consumption/daily/users/{user_id}` (URL-encoded) with the cycle's `time_after`/`time_before` → `total_acus` + per-day `acus_by_product`.
4. **Model breakdown** (Windsurf key required for the verdict). GET Windsurf `consumption` with `start_date` = cycle start, `end_date` = today, `product=agent`, `group_by=user,model_uid`, `page_size=10000`. One query — 10/hour rate limit. Keep this user's rows: `model_uid`, `billed_acus`, `message_count`. **No Windsurf key: stop after step 3's product split** and say the routing verdict needs the Windsurf service key — model-level data exists nowhere else.
5. **Classify every observed model** against the deck. The `model_uid` encodes model + effort variant (and Fast/Fusion where applicable). Buckets:
   - **Aligned** — matches the deck's routing table for some tier: Adaptive, GPT-6 Luna (any level), SWE-2 Medium/High, GPT-6 Sol Medium, Claude Opus 5.5 Low/Medium/High, Fusion pairs (Fable 5.1 or GPT-6 Astra lead + SWE-2 or GPT-5.6 Luna sidekick).
   - **Misrouted** — the deck names a strictly better route: Claude Sonnet 5 at any level (explicit avoid), legacy Claude Opus 4.7/4.8/5, Claude Fable 5/5.1 running solo (Fusion lead or Opus 5.5 Medium is the route), GPT-6 Astra solo, GPT-5.6 Sol (costs more than GPT-6 Sol at our rates), any Fast variant, any XHigh/Max effort on a frontier Claude model, Gemini/Grok/GLM/Kimi/DeepSeek/Arena models (not in the routing table at all).
   - For each misrouted model, name the deck's replacement and both cost-per-task figures from the "Price by thinking level" table (e.g. Sonnet 5 Medium $3.16 → Opus 5.5 Medium $0.67, higher score).
6. **Fusion check.** Report whether any Fusion pair appears in their usage. If frontier solo models (Fable, Astra, Opus Max/XHigh) dominate their burn, the recommendation is Fusion: Fable 5.1 Medium lead + SWE-2 Medium sidekick ($1.67 a task vs $2.68 solo, same score). If their work is single-module fixes, the recommendation is Opus 5.5 Medium solo instead — do not push Fusion where the deck says solo Opus is cheaper.
7. **Verdict.** `misrouted_share` = misrouted ACUs / total model-attributed ACUs for the cycle. Show the division.
   - **ALIGNED** (`misrouted_share < 0.10` and no avoid-list model in their top 5 by ACUs): print exactly the line `No routing alignment needed.` followed by a 3–5 line confirmation (total cycle ACUs, top 3 models with shares, the deck tier each maps to). **Do not draft an email.**
   - **MISROUTED** (anything else): produce the chat report (step 8) and the email draft (step 9).
8. **Chat report** (≤ 50 lines, show your work):
   - Headline: name, cycle ACUs consumed, effective cap if already in hand (do not spend extra calls on it), misrouted share.
   - Model table: `model_uid`, ACUs, share, verdict (aligned/misrouted), deck replacement + cost-per-task delta for each misrouted row.
   - Fusion line: using it or not, and whether it is the right route for them.
   - One primary recommendation: the single model + effort switch that moves the most ACUs, with the projected saving (deck cost-per-task ratio × their ACUs on that model).
9. **Email draft.** One fenced plain-text block, ready to paste into Outlook. Hard requirements:
   - **10–20 lines total**, greeting and sign-off included. No tables, no bullets with sub-bullets, no markdown syntax inside the block.
   - Director-to-anyone register: direct, factual, respectful, zero fluff, no scolding.
   - First line: `Subject: ACU routing alignment — <first name>`.
   - Body must carry: their cycle ACU number, the top misrouted model with its share, the deck's recommended model + effort with the cost-per-task comparison, the Fusion recommendation when step 6 produced one, and one clear ask (switch the default model in their picker). Close with an offer to help and the deck as reference. Sign off as Amit.
   - Numbers come from steps 3–8 — never invent or round beyond one decimal.
