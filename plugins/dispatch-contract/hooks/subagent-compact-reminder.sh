#!/bin/bash
# Read-only advisory hook. Missing runtime or unreadable inputs never block a tool.
command -v python3 >/dev/null 2>&1 || exit 0
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
python3 -B "$SCRIPT_DIR/subagent-compact-reminder.py" 2>/dev/null || true
