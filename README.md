# smart-index — Claude Code Skill

A Claude Code skill that uses **Gemini CLI as a codebase explorer** before reading any files, saving your Claude context budget.

> Gemini = Explorer. Claude = Builder.

## Install (WSL)

```bash
curl -fsSL https://raw.githubusercontent.com/icediceice/smart-indexer/main/SKILL.md -o ~/.claude/commands/smart-index.md
```

That's it. Restart Claude Code and the `/smart-index` skill will be available.

## What it does

- At session start, automatically runs `index_summarize` via Gemini to map the codebase architecture
- Before reading any unknown file, forces `index_query` first to get exact file paths
- Replaces blind `grep`, `find`, and `ls` searches with targeted Gemini queries
- After context compaction, re-orients with `index_summarize` before continuing

## Requirement

Gemini CLI must be installed:

```bash
npm install -g @google/gemini-cli && gemini
```
