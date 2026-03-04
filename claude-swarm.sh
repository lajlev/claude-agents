#!/usr/bin/env bash
# ============================================================================
# claude-swarm.sh — Multi-agent Claude Code orchestrator in tmux
#
# Layout:  4 panes in one tmux window
#   ┌──────────────┬──────────────┐
#   │  PM (top-L)  │ Agent1(top-R)│
#   ├──────────────┼──────────────┤
#   │ Agent2(bot-L)│ Agent3(bot-R)│
#   └──────────────┴──────────────┘
#
# The Product Manager runs in interactive mode so YOU can see its
# conversation and intervene when it escalates critical questions.
# The 3 Code Agents run in interactive mode in their own panes.
#
# Usage:
#   chmod +x claude-swarm.sh
#   ./claude-swarm.sh [project-dir]
#
# Requirements: tmux, claude (Claude Code CLI)
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SESSION_NAME="claude-swarm"
PROJECT_DIR="${1:-.}"                         # default: current directory
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"     # resolve to absolute path

# Colors for pane titles (using tmux pane-border-format)
PM_COLOR="#[fg=yellow,bold]"
AGENT_COLOR="#[fg=cyan]"

# CLAUDE.md instructions injected into each role
# Note: using read -r -d '' instead of $(cat <<HEREDOC) to avoid bash 3.2
# parser bug with parentheses inside heredocs in command substitutions.
read -r -d '' PM_SYSTEM <<'PROMPT' || true
You are the PRODUCT MANAGER in a multi-agent Claude Code swarm.

## Your role
- You coordinate 3 Code Agents working in parallel in adjacent tmux panes.
- You break down the user's high-level goal into concrete tasks.
- You assign tasks DIRECTLY to agents using tmux send-keys commands.
- You review work, unblock agents, answer their technical questions, and keep the project on track.

## How to communicate with agents
Send tasks to agents by running bash commands. Always use a single one-line message followed by Enter:
- Agent 1: tmux send-keys -t claude-swarm:0.1 "your one-line task here" Enter
- Agent 2: tmux send-keys -t claude-swarm:0.2 "your one-line task here" Enter
- Agent 3: tmux send-keys -t claude-swarm:0.3 "your one-line task here" Enter

Rules for sending messages:
- ALWAYS send a single one-line message. Never multi-line.
- ALWAYS end with Enter to submit the message.
- Keep task descriptions clear and self-contained in one line.
- Agents will automatically report back to you when they finish or get blocked.

## Task management
- You have access to Task Master AI via MCP tools. Use it to manage tasks.
- At the start, use parse_prd or create tasks manually with Task Master.
- Track all work items as tasks and subtasks.
- Update task status as agents report progress.
- Use get_tasks to review overall progress.
- Use next_task to determine what to assign next.

## Communication rules
- ONLY escalate to the human operator when:
  - A decision has significant business/product impact
  - There is ambiguity in requirements that you cannot resolve
  - A task would delete data, cost money, or deploy to production
  - Two agents have a conflicting approach and you need a tiebreaker
- For everything else, handle it yourself.
- When you DO escalate, prefix your message with "ESCALATION:" so the operator can spot it quickly.

## Workflow
1. Ask the human for the high-level goal only once at the start.
2. Create tasks in Task Master based on the goal.
3. Send tasks directly to agents using tmux send-keys commands.
4. Wait for agents to report back. They will send status updates to your pane automatically.
5. Update task status as work completes. Assign next tasks. Iterate until done.
PROMPT

# Agent system prompts are generated per-agent in the file writing section below,
# so each agent knows its number and how to report back to the PM.

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v tmux &>/dev/null; then
    echo "❌ tmux is not installed. Install it first (e.g. brew install tmux / apt install tmux)"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "❌ Claude Code CLI ('claude') not found in PATH."
    echo "   Install: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

# Kill existing session if any
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Write temporary CLAUDE.md files for each role
# ---------------------------------------------------------------------------
SWARM_DIR="$PROJECT_DIR/.claude-swarm"
mkdir -p "$SWARM_DIR"

printf '%s' "$PM_SYSTEM" > "$SWARM_DIR/pm-prompt.txt"

# Generate per-agent prompt files (each agent knows its number and how to report back)
for AGENT_NUM in 1 2 3; do
    cat > "$SWARM_DIR/agent${AGENT_NUM}-prompt.txt" << AGENTEOF
You are CODE AGENT ${AGENT_NUM} in a multi-agent Claude Code swarm.

## Your role
- You receive specific, scoped coding tasks from the Product Manager.
- You execute them thoroughly: write code, run tests, fix bugs.
- When done, you report back to the PM automatically via tmux.

## Reporting back to the PM
When you complete your task, report to the Product Manager by running:
tmux send-keys -t claude-swarm:0.0 "AGENT ${AGENT_NUM} DONE: <one-line summary of what you did>" Enter

If you are blocked and need help, report it:
tmux send-keys -t claude-swarm:0.0 "AGENT ${AGENT_NUM} BLOCKED: <what you need>" Enter

IMPORTANT: Always use a single one-line message followed by Enter. Never multi-line.

## Rules
- Stay focused on your assigned task. Do not wander into other agents' work.
- Prefer small, testable commits.
- If a task is unclear, ask ONE clarifying question to the PM via tmux send-keys, then proceed with your best judgment.
AGENTEOF
done

# Generate MCP config for task-master-ai (used by PM only)
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
# Build the tmux session
# ---------------------------------------------------------------------------
# Create session with first pane (PM)
tmux new-session -d -s "$SESSION_NAME" -x 220 -y 55 -c "$PROJECT_DIR"

# Enable pane titles
tmux set-option -t "$SESSION_NAME" pane-border-status top
tmux set-option -t "$SESSION_NAME" pane-border-format \
    " #{pane_title} "
tmux set-option -t "$SESSION_NAME" pane-border-style "fg=colour240"
tmux set-option -t "$SESSION_NAME" pane-active-border-style "fg=green,bold"

# Split into 4 panes (2x2 grid)
#   Pane 0: top-left  (PM)         │ Pane 1: top-right (Agent 1)
#   Pane 2: bottom-left (Agent 2)  │ Pane 3: bottom-right (Agent 3)
tmux split-window -h -t "$SESSION_NAME:0.0" -c "$PROJECT_DIR"   # left | right
tmux split-window -v -t "$SESSION_NAME:0.0" -c "$PROJECT_DIR"   # split left top/bottom
tmux split-window -v -t "$SESSION_NAME:0.1" -c "$PROJECT_DIR"   # split right top/bottom
tmux select-layout -t "$SESSION_NAME" tiled                       # even 2x2 grid

# Name the panes and set visual distinction
# Prevent applications (claude) from overriding pane titles
tmux set-option -t "$SESSION_NAME" allow-rename off
tmux select-pane -t "$SESSION_NAME:0.0" -T ">>> PRODUCT MANAGER <<<"
tmux select-pane -t "$SESSION_NAME:0.1" -T "Code Agent 1"
tmux select-pane -t "$SESSION_NAME:0.2" -T "Code Agent 2"
tmux select-pane -t "$SESSION_NAME:0.3" -T "Code Agent 3"

# Highlight PM pane with a distinct background
tmux select-pane -t "$SESSION_NAME:0.0" -P 'bg=colour234'

# ---------------------------------------------------------------------------
# Launch Claude Code in each pane
# ---------------------------------------------------------------------------

# Launch claude in each pane, reading system prompts from files at runtime
# (avoids shell escaping issues with multi-line text in tmux send-keys)

# Product Manager (interactive — with Task Master AI via MCP)
tmux send-keys -t "$SESSION_NAME:0.0" \
    "claude --permission-mode bypassPermissions --mcp-config '$SWARM_DIR/mcp.json' --system-prompt \"\$(cat '$SWARM_DIR/pm-prompt.txt')\"" Enter

# Agent 1
tmux send-keys -t "$SESSION_NAME:0.1" \
    "claude --permission-mode bypassPermissions --system-prompt \"\$(cat '$SWARM_DIR/agent1-prompt.txt')\"" Enter

# Agent 2
tmux send-keys -t "$SESSION_NAME:0.2" \
    "claude --permission-mode bypassPermissions --system-prompt \"\$(cat '$SWARM_DIR/agent2-prompt.txt')\"" Enter

# Agent 3
tmux send-keys -t "$SESSION_NAME:0.3" \
    "claude --permission-mode bypassPermissions --system-prompt \"\$(cat '$SWARM_DIR/agent3-prompt.txt')\"" Enter

# Focus on the PM pane
tmux select-pane -t "$SESSION_NAME:0.0"

# ---------------------------------------------------------------------------
# Attach
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           🐝  Claude Swarm is starting up!                  ║"
echo "║                                                             ║"
echo "║  Layout:                                                    ║"
echo "║  ┌──────────────────┬─────────────────┐                    ║"
echo "║  │ >>> PRODUCT MGR  │  Code Agent 1   │                    ║"
echo "║  ├──────────────────┼─────────────────┤                    ║"
echo "║  │  Code Agent 2    │  Code Agent 3   │                    ║"
echo "║  └──────────────────┴─────────────────┘                    ║"
echo "║                                                             ║"
echo "║  Tips:                                                      ║"
echo "║  • Talk to the PM in the top-left pane                     ║"
echo "║  • Switch panes: Ctrl+B then arrow keys                    ║"
echo "║  • Scroll pane:  Ctrl+B then [                             ║"
echo "║  • Detach:       Ctrl+B then d                             ║"
echo "║  • Reattach:     tmux attach -t claude-swarm               ║"
echo "║  • Kill all:     tmux kill-session -t claude-swarm         ║"
echo "║                                                             ║"
echo "║  The PM will only escalate critical decisions to you.       ║"
echo "║  Look for ⚠️  ESCALATION: messages.                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

tmux attach-session -t "$SESSION_NAME"
