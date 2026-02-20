# smart-index

A Claude Code skill that uses Gemini CLI as a codebase explorer, keeping Claude's context clean and lean throughout long development sessions.

---

## The Problem

Every file Claude reads lands in its context window permanently. It never leaves. It accumulates across the session, and every subsequent message pays the full input token cost of everything Claude has ever read.

On a large repo this compounds fast:
- Read 10 files early in a session
- Every message after that is 10 files heavier on input tokens
- Context fills, compaction triggers, session coherence degrades
- Claude loses working memory and has to re-read files it already processed

This isn't just a token cost problem — it's a session quality problem. A polluted context means every operation for the rest of the session runs slower and costs more.

---

## The Architecture

**Gemini = Explorer. Claude = Builder.**

Gemini CLI handles all file exploration. It reads files, digests them, and returns structured JSON summaries. Claude receives only the answer — never the raw content.

```
Claude asks: "where is JWT validation handled?"
        ↓
Gemini reads the entire codebase (stateless, disposable)
        ↓
Gemini returns: {"locations": [{"file": "auth/middleware.py", "context": "validates JWT on every request"}]}
        ↓
Claude reads only auth/middleware.py
```

The raw file content never touches Claude's context. Gemini's context is cheap and stateless — it resets after every call. Claude's context is scarce and permanent — it should only hold things that matter for the actual work.

---

## Measured Results

Tested on a production-complexity NKP demo repo (~12 services, ArgoCD, Istio, Kustomize overlays, Python microservices).

**Single index_batch call (3 questions):**

| Metric | Value |
|--------|-------|
| Gemini file content processed | ~21,512 tokens |
| Claude received back (JSON) | ~562 tokens |
| Claude context saved | ~20,950 tokens |
| Leverage ratio | **37:1** |

Without smart-index, Claude would have run glob/grep searches, read 7+ raw files, and held all that content in context permanently. Every message for the rest of the session would pay the input token cost of those files.

**Session coherence:** On a 100k token repo, smart-index extends productive session length from ~30 minutes to hours by preventing context accumulation that triggers compaction.

---

## Why Context Pricing Matters

Right now AI companies charge primarily by tokens in/out per request. As sessions grow longer and context windows expand, the natural next pricing dimension is **context occupancy** — how much of that window you hold and for how long.

Every file read that stays in context is a liability that compounds across every subsequent message. This architecture treats Claude's context as the scarce resource it is — and will increasingly be priced as.

---

## Token Economics

Every headless Gemini CLI call is a cold session — no cache persists between bash invocations. Each call costs ~9k tokens minimum as fixed overhead.

**This is why batching is critical.** Use `index_batch` for 2+ questions:

| Approach | Gemini calls | Tokens |
|----------|-------------|--------|
| 3× index_query | 3 | ~27k |
| 1× index_batch | 1 | ~9-32k |

The fixed overhead is unavoidable — spread it across as many questions as possible.

**Model fallback chain:** `gemini-2.5-flash` → `gemini-3-flash-preview` → switch account

Note: `gemini-2.5-flash` and `gemini-2.5-flash-lite` share the same quota bucket. Gemini 3 Flash is a genuinely separate quota bucket and is the correct fallback.

---

## Setup

### New machine (5 commands)
```bash
npm install -g @google/gemini-cli
git clone https://github.com/USER/smart-index-skill ~/.claude/skills/smart-index
echo 'Read and follow: ~/.claude/skills/smart-index/SKILL.md' >> ~/.claude/CLAUDE.md
gemini  # OAuth login once
```

### Or run setup.sh
```bash
bash setup.sh
source ~/.zshrc  # or ~/.bashrc
gemini           # OAuth login
```

### Test
```bash
gemini --yolo -m gemini-2.5-flash -p "say hello" --output-format json
```

---

## Tools

| Tool | When to use |
|------|------------|
| `index_batch` | 2+ unknowns — always batch, never loop |
| `index_query` | Single location lookup |
| `index_analyze` | Cross-file behavior before modifying |
| `index_trace` | Call chain or data flow debugging |
| `index_summarize` | Session start and after compaction |
