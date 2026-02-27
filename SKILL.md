---
name: smart-index
description: MANDATORY - Use Gemini CLI as a smart codebase index before reading any files. This skill MUST be invoked at session start and before ANY file read when location is unknown. Gemini is the explorer agent, Claude is the builder. Violating this rule wastes user's Claude budget. Never read blind.
---

# Smart Index Skill

## ⚠️ MANDATORY BEHAVIOR — NOT OPTIONAL

This skill defines **required** behavior, not suggestions. Reading files without querying the index first is a violation that wastes the user's Claude context budget. When in doubt — query first, read after.

---

## Model Strategy

All tools use `gemini-2.5-flash` with automatic fallback to `gemini-3-flash-preview` if quota or RPM limit is hit. Gemini re-reads files fresh on every call — every headless bash invocation is a cold session, no cache persists between calls. Each call costs ~9k tokens minimum, so batching questions is critical.

**Fallback chain:** `gemini-2.5-flash` → `gemini-3-flash-preview` → error with account switch prompt

Note: `gemini-2.5-flash` and `gemini-2.5-flash-lite` share the same quota bucket — no point falling back between them. `gemini-3-flash-preview` is a separate bucket. Fallback handles both daily quota exhaustion and RPM rate limits.

All calls use `--yolo` to skip confirmation prompts and `--output-format json` for structured output.

### ⚠️ Headless Mode ONLY — Never Use Agent Mode

**All smart-index calls MUST use headless mode (`gemini -p "..."`).**  Never use Gemini CLI in interactive/agent mode for this skill. Agent mode lets Gemini chain its own tool calls internally — reading files, running commands, reading more files — and each internal step burns model requests against the same RPM/RPD quota. A single agent-mode prompt on a medium codebase can consume 20–50+ model requests as it autonomously explores. That's your entire minute budget gone in one call.

Headless mode with `-p` forces a single request-response cycle: one prompt in, one answer out. This is the only mode that gives predictable, controllable quota consumption. The skill is designed around this constraint — every prompt is structured to extract maximum information in one shot.

**Never do this:**
```bash
# ❌ VIOLATION — agent mode, uncontrolled quota burn
gemini --yolo -m gemini-2.5-flash "Explore this codebase and find all auth-related files"
```

**Always do this:**
```bash
# ✅ REQUIRED — headless mode, single request-response
gemini --yolo -m gemini-2.5-flash -p "Locate all auth-related files..." --output-format json
```

The `-p` flag is non-negotiable. Without it, Gemini enters agent mode and will eat quota faster than you can blink.

### Rate Limits & Pacing

**Each headless `gemini -p` invocation consumes 2–5+ internal model requests** — Gemini CLI re-ingests the full codebase context on every cold call. Rapid consecutive calls will blow through RPM limits even when individual calls seem small.

**Gemini CLI quotas (per auth method):**

| Auth Method | RPM | RPD | Default Sleep |
|-------------|-----|------|---------------|
| OAuth — AI Pro *(default)* | 120 | 1,500 | 5s |
| OAuth — Free tier | 60 | 1,000 | 8s |
| OAuth — AI Ultra / Enterprise | 120 | 2,000 | 5s |
| API Key — Free tier | 10 | 250 | 12s |
| API Key — Paid tier | 150+ | 1,500+ | 3s |
| Vertex AI | Variable | Variable | 3s |

**HARD RULE: Always pace between Gemini calls.** This is a simple deterministic `sleep` — never use an AI call to check quota status, that just burns more quota.

The user can override the sleep interval: `export SMART_INDEX_SLEEP=3`

### ⚠️ Claude Agent Batching — CRITICAL

**Claude Code (CC) runs each bash tool call in its own shell.** Environment variables do not persist between separate bash invocations. Worse, CC can emit multiple bash tool calls in a single response turn, executing them **in parallel** — which defeats any in-script sleep pacing entirely.

**HARD RULES for Claude's own agent behavior:**
1. **Never issue more than one Gemini CLI bash call per response turn.** If a task needs `index_summarize` then `index_batch`, do them in **separate response turns** (output one, wait for result, then output the next) — or combine them into a **single bash script block**.
2. **Prefer combining multiple Gemini calls into one bash block** when they must run sequentially (e.g., session start). This keeps pacing logic in one shell where timestamps persist.
3. **Never run Gemini CLI calls in parallel.** No parallel tool_use blocks, no background subshells (`&`), no xargs parallelism.

**Pacing uses a file-based timestamp** at `/tmp/.smart_index_last` so it survives across separate bash invocations:

### Reusable fallback wrapper — use this pattern for every tool call:
```bash
# Pacing: file-based timestamp survives across separate bash calls
_SI_SLEEP="${SMART_INDEX_SLEEP:-5}"
_SI_LAST=$(cat /tmp/.smart_index_last 2>/dev/null || echo 0)
_SI_NOW=$(date +%s)
_SI_ELAPSED=$((_SI_NOW - _SI_LAST))
if [ "$_SI_ELAPSED" -lt "$_SI_SLEEP" ]; then
  _SI_WAIT=$((_SI_SLEEP - _SI_ELAPSED))
  echo "[smart-index] Pacing: waiting ${_SI_WAIT}s before next call..."
  sleep "$_SI_WAIT"
fi

PROMPT="..."
date +%s > /tmp/.smart_index_last
RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  sleep "$_SI_SLEEP"
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo "[smart-index] Rate limited on both models. Waiting 30s before retry..."
  sleep 30
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo '[smart-index] {"error": "all_models_limited", "action": "Switch Google account: gemini auth login"}'
else
  echo "$RESULT"
fi
```

---

## REQUIRED: Session Start Protocol

**Every CC session on a repo with more than 10 files MUST begin with this:**

### Step 1 — Verify Gemini CLI
```bash
which gemini && gemini --version
```
If not found, stop and install before proceeding:
```bash
npm install -g @google/gemini-cli && gemini
```

### Step 2 — Detect Auth & Configure Rate Limits
```bash
# Detect auth method and set pacing defaults
# User override always wins: export SMART_INDEX_SLEEP=3
if [ -z "$SMART_INDEX_SLEEP" ]; then
  if [ -n "$GEMINI_API_KEY" ] || [ -n "$GOOGLE_API_KEY" ]; then
    if [ -n "$GOOGLE_CLOUD_PROJECT" ]; then
      export SMART_INDEX_SLEEP=3
      echo "[smart-index] Auth: API Key (paid tier) — 3s pacing"
    else
      export SMART_INDEX_SLEEP=12
      echo "[smart-index] Auth: API Key (free tier) — 12s pacing"
    fi
  elif [ -n "$GOOGLE_CLOUD_PROJECT" ] && [ -n "$GOOGLE_CLOUD_LOCATION" ]; then
    export SMART_INDEX_SLEEP=3
    echo "[smart-index] Auth: Vertex AI — 3s pacing"
  else
    export SMART_INDEX_SLEEP=5
    echo "[smart-index] Auth: OAuth (Pro default) — 5s pacing"
  fi
fi

# Initialize file-based pacing timestamp (shared across bash invocations)
echo 0 > /tmp/.smart_index_last
echo "[smart-index] Rate limit pacing: ${SMART_INDEX_SLEEP}s between calls"
```

### Step 3 — Create .geminiignore if missing
```bash
if [ ! -f .geminiignore ]; then
cat > .geminiignore << 'EOF'
node_modules/
dist/
build/
.next/
.venv/
venv/
__pycache__/
*.log
*.lock
coverage/
.git/
*.min.js
*.min.css
*.zip
*.tar.gz
*.mp4
*.png
*.jpg
*.pdf
.idea/
.vscode/
EOF
echo "[smart-index] .geminiignore created"
fi
```

### Step 4 — Run index_summarize
```bash
PROMPT="Give me a complete architectural overview of this codebase.

Respond ONLY as JSON, no markdown:
{
  \"project_type\": \"what this project is\",
  \"tech_stack\": [\"technology1\", \"technology2\"],
  \"services\": [
    {\"name\": \"service name\", \"purpose\": \"what it does\", \"key_files\": [\"file1\"]}
  ],
  \"entry_points\": [\"how to run or start the project\"],
  \"data_flow\": \"how data moves through the system\",
  \"key_directories\": {\"dir\": \"purpose\"}
}"

# First call of session — timestamp was just initialized to 0, so pacing will skip
_SI_SLEEP="${SMART_INDEX_SLEEP:-5}"
_SI_LAST=$(cat /tmp/.smart_index_last 2>/dev/null || echo 0)
_SI_NOW=$(date +%s)
_SI_ELAPSED=$((_SI_NOW - _SI_LAST))
if [ "$_SI_ELAPSED" -lt "$_SI_SLEEP" ]; then
  sleep $((_SI_SLEEP - _SI_ELAPSED))
fi
date +%s > /tmp/.smart_index_last
RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  sleep "$_SI_SLEEP"
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo "[smart-index] Rate limited on both models. Waiting 30s before retry..."
  sleep 30
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo '[smart-index] {"error": "all_models_limited", "action": "Switch Google account: gemini auth login"}'
else
  echo "$RESULT"
fi
```

**Do not read any files before completing Step 4.**

---

## REQUIRED: Pre-Read Protocol

**Before reading ANY file whose location is not already confirmed in current context:**

```
STOP — run index_query first
```

This is non-negotiable. The only exception is if the exact file path was already returned by a previous index tool call in this session.

---

## Mandatory Trigger Rules

These are HARD RULES, not guidelines:

| Situation | REQUIRED Action |
|-----------|----------------|
| Session start on any repo > 10 files | MUST run `index_summarize` |
| 2+ file locations unknown | MUST run `index_batch` — never loop index_query |
| File location unknown (single) | MUST run `index_query` before any read |
| About to use grep, find, or ls to search | MUST run `index_batch` or `index_query` instead |
| Task involves multiple files or services | MUST run `index_analyze` first |
| Tracing a call chain or data flow | MUST run `index_trace` first |
| After compaction event | MUST run `index_summarize` before continuing |
| Any cross-service question | MUST run `index_analyze` or `index_trace` |

**Skip index tools ONLY when ALL of these are true:**
- File path is explicitly confirmed in current context from a previous index call
- Task involves only that single known file
- No cross-file understanding is needed

---

## Tool: index_batch

**USE THIS FIRST when you have 2+ unknowns. Combines multiple questions into one Gemini call — saves ~9k tokens per question avoided.**

```bash
# Pacing: file-based timestamp
_SI_SLEEP="${SMART_INDEX_SLEEP:-5}"
_SI_LAST=$(cat /tmp/.smart_index_last 2>/dev/null || echo 0)
_SI_NOW=$(date +%s)
_SI_ELAPSED=$((_SI_NOW - _SI_LAST))
if [ "$_SI_ELAPSED" -lt "$_SI_SLEEP" ]; then
  _SI_WAIT=$((_SI_SLEEP - _SI_ELAPSED))
  echo "[smart-index] Pacing: waiting ${_SI_WAIT}s..."
  sleep "$_SI_WAIT"
fi

PROMPT="Answer all of the following questions about this codebase in a single response.

Questions:
1. {QUESTION_1}
2. {QUESTION_2}
3. {QUESTION_3}

Respond ONLY as JSON, no markdown:
{
  \"answers\": [
    {
      \"question\": \"exact question text\",
      \"locations\": [{\"file\": \"relative/path\", \"context\": \"what it does here\"}],
      \"summary\": \"one sentence answer\"
    }
  ]
}"

date +%s > /tmp/.smart_index_last
RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  sleep "$_SI_SLEEP"
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo "[smart-index] Rate limited on both models. Waiting 30s before retry..."
  sleep 30
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo '[smart-index] {"error": "all_models_limited", "action": "Switch Google account: gemini auth login"}'
else
  echo "$RESULT"
fi
```

**Rule: If you have 2 or more unknowns before starting a task — batch them. Never call index_query in a loop.**

---

## Tool: index_query

**REQUIRED before any unknown file read. Use index_batch instead if you have 2+ questions.**

```bash
# Pacing: file-based timestamp
_SI_SLEEP="${SMART_INDEX_SLEEP:-5}"
_SI_LAST=$(cat /tmp/.smart_index_last 2>/dev/null || echo 0)
_SI_NOW=$(date +%s)
_SI_ELAPSED=$((_SI_NOW - _SI_LAST))
if [ "$_SI_ELAPSED" -lt "$_SI_SLEEP" ]; then
  _SI_WAIT=$((_SI_SLEEP - _SI_ELAPSED))
  echo "[smart-index] Pacing: waiting ${_SI_WAIT}s..."
  sleep "$_SI_WAIT"
fi

PROMPT="Locate the following in this codebase: {QUESTION}

Respond ONLY as JSON, no markdown:
{
  \"locations\": [
    {\"file\": \"relative/path/to/file\", \"context\": \"what it does here\"}
  ],
  \"summary\": \"one sentence answer\"
}"

date +%s > /tmp/.smart_index_last
RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  sleep "$_SI_SLEEP"
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo "[smart-index] Rate limited on both models. Waiting 30s before retry..."
  sleep 30
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo '[smart-index] {"error": "all_models_limited", "action": "Switch Google account: gemini auth login"}'
else
  echo "$RESULT"
fi
```

**After result: Read ONLY the files listed. No additional reads.**

---

## Tool: index_analyze

**REQUIRED before modifying anything that touches multiple files.**

```bash
# Pacing: file-based timestamp
_SI_SLEEP="${SMART_INDEX_SLEEP:-5}"
_SI_LAST=$(cat /tmp/.smart_index_last 2>/dev/null || echo 0)
_SI_NOW=$(date +%s)
_SI_ELAPSED=$((_SI_NOW - _SI_LAST))
if [ "$_SI_ELAPSED" -lt "$_SI_SLEEP" ]; then
  _SI_WAIT=$((_SI_SLEEP - _SI_ELAPSED))
  echo "[smart-index] Pacing: waiting ${_SI_WAIT}s..."
  sleep "$_SI_WAIT"
fi

PROMPT="Analyze the following in this codebase: {QUESTION}

Respond ONLY as JSON, no markdown:
{
  \"answer\": \"clear explanation\",
  \"relevant_files\": [\"file1\", \"file2\"],
  \"data_flow\": \"how data or control moves through the system\",
  \"warnings\": [\"anything important to know before modifying\"]
}"

date +%s > /tmp/.smart_index_last
RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  sleep "$_SI_SLEEP"
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo "[smart-index] Rate limited on both models. Waiting 30s before retry..."
  sleep 30
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo '[smart-index] {"error": "all_models_limited", "action": "Switch Google account: gemini auth login"}'
else
  echo "$RESULT"
fi
```

---

## Tool: index_trace

**REQUIRED before debugging or modifying any cross-service or cross-file flow.**

```bash
# Pacing: file-based timestamp
_SI_SLEEP="${SMART_INDEX_SLEEP:-5}"
_SI_LAST=$(cat /tmp/.smart_index_last 2>/dev/null || echo 0)
_SI_NOW=$(date +%s)
_SI_ELAPSED=$((_SI_NOW - _SI_LAST))
if [ "$_SI_ELAPSED" -lt "$_SI_SLEEP" ]; then
  _SI_WAIT=$((_SI_SLEEP - _SI_ELAPSED))
  echo "[smart-index] Pacing: waiting ${_SI_WAIT}s..."
  sleep "$_SI_WAIT"
fi

PROMPT="Trace the following flow in this codebase: from {TRACE_FROM} to {TRACE_TO}

Respond ONLY as JSON, no markdown:
{
  \"chain\": [
    {\"step\": \"1\", \"file\": \"path/to/file\", \"description\": \"what happens here\"}
  ],
  \"entry_point\": \"where it starts\",
  \"exit_point\": \"where it ends\",
  \"summary\": \"one sentence overview of the flow\"
}"

date +%s > /tmp/.smart_index_last
RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  sleep "$_SI_SLEEP"
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo "[smart-index] Rate limited on both models. Waiting 30s before retry..."
  sleep 30
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo '[smart-index] {"error": "all_models_limited", "action": "Switch Google account: gemini auth login"}'
else
  echo "$RESULT"
fi
```

---

## Tool: index_summarize

**REQUIRED at session start and after every compaction.**

```bash
# Pacing (skip sleep on first call of session — timestamp file will be old/zero)
_SI_SLEEP="${SMART_INDEX_SLEEP:-5}"
_SI_LAST=$(cat /tmp/.smart_index_last 2>/dev/null || echo 0)
_SI_NOW=$(date +%s)
_SI_ELAPSED=$((_SI_NOW - _SI_LAST))
if [ "$_SI_ELAPSED" -lt "$_SI_SLEEP" ]; then
  _SI_WAIT=$((_SI_SLEEP - _SI_ELAPSED))
  echo "[smart-index] Pacing: waiting ${_SI_WAIT}s..."
  sleep "$_SI_WAIT"
fi

PROMPT="Give me a complete architectural overview of this codebase.

Respond ONLY as JSON, no markdown:
{
  \"project_type\": \"what this project is\",
  \"tech_stack\": [\"technology1\", \"technology2\"],
  \"services\": [
    {\"name\": \"service name\", \"purpose\": \"what it does\", \"key_files\": [\"file1\"]}
  ],
  \"entry_points\": [\"how to run or start the project\"],
  \"data_flow\": \"how data moves through the system\",
  \"key_directories\": {\"dir\": \"purpose\"}
}"

date +%s > /tmp/.smart_index_last
RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  sleep "$_SI_SLEEP"
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo "[smart-index] Rate limited on both models. Waiting 30s before retry..."
  sleep 30
  date +%s > /tmp/.smart_index_last
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo '[smart-index] {"error": "all_models_limited", "action": "Switch Google account: gemini auth login"}'
else
  echo "$RESULT"
fi
```

---

## Decision Flow — Follow This Exactly

```
Session starts
      ↓
MANDATORY: Detect auth & set SMART_INDEX_SLEEP
MANDATORY: index_summarize → get architecture map
      ↓
User asks to implement or fix something
      ↓
Is exact file path confirmed from index in THIS session?
      YES → read only that file
      NO  → MANDATORY: index_query first, read only result files
      ↓
Does task touch multiple files or services?
      YES → MANDATORY: index_analyze or index_trace
      NO  → proceed with confirmed files only
      ↓
Implement using only indexed files
      ↓
Compaction occurs?
      YES → MANDATORY: index_summarize before continuing
      ↓
Quota exhausted mid-session?
      Fallback wrapper retries with backoff (5s → 30s)
      Both models exhausted → run: gemini auth login (switch account)
```

---

## Enforcement Rules

1. **Never read a file whose path was not returned by an index tool in this session**
2. **Never use bash find, grep, or ls to locate code — use index_query**
3. **Never skip session start index_summarize on repos > 10 files**
4. **Never re-read a file already read in this session — use context**
5. **Always run index_summarize after compaction before any further reads**
6. **Always use index_batch when you have 2+ unknowns — never call index_query in a loop**
7. **Always use --yolo flag — never let Gemini pause for confirmation**
8. **Always use the fallback wrapper — never call gemini directly without quota handling**
9. **Always sleep between consecutive Gemini calls — use `$SMART_INDEX_SLEEP` (default 5s). This is a simple `sleep`, not an AI check. Never skip pacing to "go faster".**
10. **Never fire more than 3 Gemini calls per user task without pausing to assess whether results so far are sufficient. Batch aggressively — prefer 1 fat call over 3 thin ones.**
11. **Plan Gemini calls before executing them. Decide upfront how many calls a task needs, batch everything possible into index_batch, and execute the minimum. Do not discover-as-you-go with sequential index_query calls.**
12. **Never use Gemini CLI without the `-p` flag. All calls MUST be headless single-shot. Agent/interactive mode causes uncontrolled internal tool chaining that will collapse quotas in minutes.**
13. **Never issue multiple Gemini CLI bash calls in the same response turn.** CC can execute parallel tool_use blocks simultaneously, defeating all pacing. One Gemini call per turn, or combine into a single bash script block.

---

## Violations — What NOT to Do

```
User: "Fix the JWT expiry bug"

❌ VIOLATION — Do not do this:
Read auth/ directory
Read middleware/ directory
Search utils/ for JWT references

✅ REQUIRED — Do this:
index_query("where is JWT token validation and expiry handled")
→ Flash returns exact files, falls back to Flash-Lite if needed
→ read only those files
→ fix bug
```

```
User: "Why isn't inventory updating when order is placed?"

❌ VIOLATION — Do not do this:
Read order service files
Read inventory service files
Read message queue config

✅ REQUIRED — Do this:
index_trace("POST /orders endpoint", "inventory update")
→ Flash traces full chain across all files
→ read only chain files
→ debug
```

```
Compaction occurs mid-session

❌ VIOLATION — Do not do this:
Resume and re-read files from earlier session

✅ REQUIRED — Do this:
index_summarize()
→ re-orient in seconds
→ continue
```

```
User: "Explore the Blink codebase and tell me how navigation works"

❌ VIOLATION — Do not do this:
index_summarize()
index_query("navigation component")
index_query("router setup")
index_query("screen definitions")
index_query("deep linking")
index_query("bottom nav bar")
→ 6 calls in 30 seconds, blows RPM quota

✅ REQUIRED — Do this:
index_summarize()
→ sleep 5s
index_batch([
  "where is the navigation/router setup",
  "where are screen/page components defined",
  "how does deep linking or bottom navigation work"
])
→ 2 calls total, same information, quota intact
```

```
User: "Analyze the auth flow in this project"

❌ VIOLATION — Do not do this:
gemini --yolo "Explore the auth system and trace how login works"
→ Agent mode: Gemini autonomously reads 15 files, runs 3 commands,
   chains 25+ internal model requests in ~60 seconds
→ RPM quota gone, daily budget drained, session dead

✅ REQUIRED — Do this:
gemini --yolo -m gemini-2.5-flash -p "Trace the auth flow..." --output-format json
→ Headless mode: 1 prompt, 1 response, 2-5 model requests
→ Predictable, controlled, quota-safe
```
