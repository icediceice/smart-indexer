---
name: smart-index
description: MANDATORY - Use Gemini CLI as a smart codebase index before reading any files. This skill MUST be invoked at session start and before ANY file read when location is unknown. Gemini is the explorer agent, Claude is the builder. Violating this rule wastes user's Claude budget. Never read blind.
---

# Smart Index Skill

## ⚠️ MANDATORY BEHAVIOR — NOT OPTIONAL

This skill defines **required** behavior, not suggestions. Reading files without querying the index first is a violation that wastes the user's Claude context budget. When in doubt — query first, read after.

**Gemini = Explorer. Claude = Builder.**

---

## Model Strategy

All tools use `gemini-2.5-flash` with automatic fallback to `gemini-3-flash-preview` if quota or RPM limit is hit. Gemini re-reads files fresh on every call — every headless bash invocation is a cold session, no cache persists between calls. Each call costs ~9k tokens minimum, so batching questions is critical.

**Fallback chain:** `gemini-2.5-flash` → `gemini-3-flash-preview` → error with account switch prompt

Note: `gemini-2.5-flash` and `gemini-2.5-flash-lite` share the same quota bucket — no point falling back between them. `gemini-3-flash-preview` is a separate bucket. Fallback handles both daily quota exhaustion and RPM rate limits.

All calls use `--yolo` to skip confirmation prompts and `--output-format json` for structured output.

**Reusable fallback wrapper — use this pattern for every tool call:**
```bash
PROMPT="..."
RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
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

### Step 2 — Create .geminiignore if missing
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

### Step 3 — Run index_summarize
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

RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
fi
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted\|not.found\|unavailable"; then
  echo '[smart-index] {"error": "all_models_limited", "action": "Switch Google account: gemini auth login"}'
else
  echo "$RESULT"
fi
```

**Do not read any files before completing Step 3.**

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

RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
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
PROMPT="Locate the following in this codebase: {QUESTION}

Respond ONLY as JSON, no markdown:
{
  \"locations\": [
    {\"file\": \"relative/path/to/file\", \"context\": \"what it does here\"}
  ],
  \"summary\": \"one sentence answer\"
}"

RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
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
PROMPT="Analyze the following in this codebase: {QUESTION}

Respond ONLY as JSON, no markdown:
{
  \"answer\": \"clear explanation\",
  \"relevant_files\": [\"file1\", \"file2\"],
  \"data_flow\": \"how data or control moves through the system\",
  \"warnings\": [\"anything important to know before modifying\"]
}"

RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
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

RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
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

RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-2.5-flash -p "$PROMPT" --output-format json 2>&1)
if echo "$RESULT" | grep -qi "quota\|rate.limit\|429\|exhausted"; then
  echo "[smart-index] Flash limit hit, falling back to Gemini 3 Flash Preview..."
  RESULT=$(cd {REPO_PATH} && gemini --yolo -m gemini-3-flash-preview -p "$PROMPT" --output-format json 2>&1)
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
      Flash-Lite fallback triggers automatically
      Both exhausted → run: gemini auth login (switch account)
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
