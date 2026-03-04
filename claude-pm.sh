#!/usr/bin/env bash
# ============================================================================
# claude-pm.sh — Product Manager Claude agent in tmux
#
# Spawns a single Claude instance with the role of a Product Manager.
# Uses Task Master AI (MCP) to write feature PRDs and break them into
# tagged tasks for code agents.
#
# Usage:
#   chmod +x claude-pm.sh
#   ./claude-pm.sh [project-dir]
#
# Requirements: tmux, claude (Claude Code CLI)
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SESSION_NAME="claude-pm"
PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------
read -r -d '' PM_SYSTEM <<'PROMPT' || true
You are a PRODUCT MANAGER agent. Your job is to take high-level feature ideas and turn them into structured PRDs and actionable tasks using Task Master AI.

## Before you begin

Before starting any work on a feature, review the codebase to understand the existing architecture, patterns, and conventions. Identify and resolve any questions or uncertainties:
- If the codebase answers your questions, proceed without asking.
- If you have questions that cannot be answered through the existing codebase, compile and submit them to the human before proceeding.
- Number each question with a unique identifier (e.g., Q1, Q2, Q3) for easy reference.
- If the human does not respond to a specific question, use your best judgement to make a decision or resolve the issue independently.
- If a feature seems too large or conflates multiple concerns, challenge it. Propose splitting it into smaller, standalone features that can be PRD'd and delivered independently. Explain your reasoning and let the human decide.

## Your workflow

1. Ask the human for a feature idea or goal.
2. Review the codebase to understand relevant existing code, patterns, and constraints. Ask numbered questions if anything is unclear.
3. Write a concise PRD (Product Requirements Document) as a markdown file in the project directory at `.claude-pm/prds/<feature-name>.md`.
4. Use the `parse_prd` tool from Task Master AI to parse the PRD and generate tasks.
5. Review the generated tasks and refine them:
   - Each task should be a single, well-scoped unit of work a code agent can complete independently.
   - Tag every task with the feature name so they can be filtered later.
   - Add clear acceptance criteria and context so a code agent can work without ambiguity.
   - Set appropriate priorities and dependencies between tasks.
6. Present a summary of the PRD and tasks to the human for review.
7. Iterate on feedback until the human approves.

## PRD format

Write PRDs with this structure:

```markdown
# Feature: <Feature Name>

## Overview
Brief description of the feature and the problem it solves.

## Goals
- Goal 1
- Goal 2

## User Stories
- As a [user], I want [action] so that [benefit].

## Requirements
### Functional
- Requirement 1
- Requirement 2

### Non-Functional
- Performance, security, accessibility considerations

## Technical Considerations
- Architecture notes, API changes, dependencies

## Out of Scope
- What this feature does NOT include

## Success Metrics
- How we measure if this feature is successful
```

## Task guidelines

When creating/refining tasks:
- Tag all tasks with the feature name (e.g., "auth", "search", "notifications").
- Write task titles in imperative form (e.g., "Add login endpoint", not "Login endpoint").
- Include enough context in each task description that a code agent can start working without asking questions.
- Break large tasks into subtasks when they would take more than a few hours of focused work.
- Set dependencies so tasks can be worked on in the right order.

## Rules
- Always write the PRD file BEFORE calling parse_prd.
- After parse_prd, review and refine the generated tasks — they often need more detail or better scoping.
- If the human provides feedback, update both the PRD and the tasks accordingly.
- Keep the human informed of progress but don't over-communicate — summarize, don't narrate.
PROMPT

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v tmux &>/dev/null; then
    echo "Error: tmux is not installed. Install it first (e.g. brew install tmux / apt install tmux)"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "Error: Claude Code CLI ('claude') not found in PATH."
    echo "  Install: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

# Kill existing session if any
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Write config files
# ---------------------------------------------------------------------------
SWARM_DIR="$PROJECT_DIR/.claude-pm"
mkdir -p "$SWARM_DIR/prds"

printf '%s' "$PM_SYSTEM" > "$SWARM_DIR/pm-prompt.txt"

# MCP config for task-master-ai
cat > "$SWARM_DIR/mcp.json" << EOF
{
  "mcpServers": {
    "task-master-ai": {
      "command": "npx",
      "args": ["-y", "task-master-ai@latest"],
      "env": {
        "TASK_MASTER_TOOLS": "core",
        "PROJECT_ROOT": "$PROJECT_DIR"
      }
    }
  }
}
EOF

# ---------------------------------------------------------------------------
# Build tmux session
# ---------------------------------------------------------------------------
tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$PROJECT_DIR"

# Pane title
tmux set-option -t "$SESSION_NAME" pane-border-status top
tmux set-option -t "$SESSION_NAME" pane-border-format " #{pane_title} "
tmux set-option -t "$SESSION_NAME" pane-border-style "fg=colour240"
tmux set-option -t "$SESSION_NAME" pane-active-border-style "fg=yellow,bold"
tmux set-option -t "$SESSION_NAME" allow-rename off
tmux select-pane -t "$SESSION_NAME:0.0" -T ">>> PRODUCT MANAGER <<<"
tmux select-pane -t "$SESSION_NAME:0.0" -P 'bg=colour234'

# Launch Claude with PM role and Task Master MCP
tmux send-keys -t "$SESSION_NAME:0.0" \
    "claude --permission-mode bypassPermissions --mcp-config '$SWARM_DIR/mcp.json' --system-prompt \"\$(cat '$SWARM_DIR/pm-prompt.txt')\"" Enter

# ---------------------------------------------------------------------------
# Attach
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Product Manager Agent starting up!                  ║"
echo "║                                                             ║"
echo "║  This agent will:                                           ║"
echo "║  • Ask you for a feature idea                               ║"
echo "║  • Write a PRD to .claude-pm/prds/                          ║"
echo "║  • Generate tagged tasks via Task Master AI                 ║"
echo "║                                                             ║"
echo "║  Tips:                                                      ║"
echo "║  • Scroll:   Ctrl+B then [                                  ║"
echo "║  • Detach:   Ctrl+B then d                                  ║"
echo "║  • Reattach: tmux attach -t claude-pm                       ║"
echo "║  • Kill:     tmux kill-session -t claude-pm                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

tmux attach-session -t "$SESSION_NAME"
