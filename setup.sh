#!/bin/bash
# smart-index setup script
# Run once on any new machine to install the skill

set -e

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SKILLS_DIR="$CLAUDE_DIR/skills/smart-index"

echo "[smart-index] Setting up..."

# 1. Check Node.js
if ! which node > /dev/null 2>&1; then
  echo "[smart-index] ERROR: Node.js not found. Install from https://nodejs.org (LTS)"
  exit 1
fi

# 2. Install Gemini CLI if not present
if ! which gemini > /dev/null 2>&1; then
  echo "[smart-index] Installing Gemini CLI..."
  npm install -g @google/gemini-cli
else
  echo "[smart-index] Gemini CLI already installed: $(gemini --version)"
fi

# 3. Create ~/.claude/skills/smart-index/
mkdir -p "$SKILLS_DIR"
cp "$SKILL_DIR/SKILL.md" "$SKILLS_DIR/SKILL.md"
echo "[smart-index] Skill copied to $SKILLS_DIR"

# 4. Add skill reference to ~/.claude/CLAUDE.md if not already there
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
mkdir -p "$CLAUDE_DIR"

if ! grep -q "smart-index" "$CLAUDE_MD" 2>/dev/null; then
  cat >> "$CLAUDE_MD" << 'EOF'

## Skills

### smart-index
Read and follow: ~/.claude/skills/smart-index/SKILL.md

Use Gemini CLI as a smart codebase index before reading files in any large repo session.
Gemini is the explorer. Claude is the builder. Never read blind.
EOF
  echo "[smart-index] Added skill reference to $CLAUDE_MD"
else
  echo "[smart-index] Skill reference already in $CLAUDE_MD, skipping"
fi

echo ""
# 5. Add Gemini performance env vars to shell profile
SHELL_PROFILE="$HOME/.zshrc"
[ -f "$HOME/.bashrc" ] && SHELL_PROFILE="$HOME/.bashrc"

if ! grep -q "GEMINI_YOLO" "$SHELL_PROFILE" 2>/dev/null; then
  cat >> "$SHELL_PROFILE" << 'EOF'

# smart-index: Gemini CLI performance settings
export GEMINI_YOLO=true
EOF
  echo "[smart-index] Added GEMINI_YOLO=true to $SHELL_PROFILE"
  echo "[smart-index] Run: source $SHELL_PROFILE"
else
  echo "[smart-index] Gemini env vars already set, skipping"
fi

echo ""
echo "[smart-index] Setup complete."
echo ""
echo "Next steps:"
echo "  1. source $SHELL_PROFILE"
echo "  2. Login to Gemini CLI with your Google account:"
echo "     gemini"
echo ""
echo "Then test it:"
echo "  gemini --yolo -m gemini-2.5-flash -p 'say hello' --output-format json"
