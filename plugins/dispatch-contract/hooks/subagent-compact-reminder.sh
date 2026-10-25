#!/bin/bash
# Read-only advisory hook. Missing runtime or unreadable inputs never block a tool.
command -v python3 >/dev/null 2>&1 || exit 0
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
# stderr is kept (not discarded): a fail-open path that swallows Python errors
# is how a silent, months-long no-op went unnoticed. Hook contract is "never
# block the tool", not "never speak", so a diagnostic line on stderr is safe.
python3 -B "$SCRIPT_DIR/subagent-compact-reminder.py" || true
