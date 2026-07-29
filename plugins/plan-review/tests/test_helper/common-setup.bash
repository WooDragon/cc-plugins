#!/bin/bash
# Common test infrastructure for plan-review hook BDD tests.
#
# Provides: isolated temp dirs, mock engine generators, input builders,
# assertion helpers. All paths are injected via env vars so production
# paths are never touched.

# Paths to scripts under test
HOOK_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/plan-review.sh"
PRECOMPACT_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/precompact-review.sh"
DISPATCH_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/dispatch-check.sh"

# --- Setup / Teardown ---

common_setup() {
  TEST_TEMP_DIR=$(mktemp -d)

  # Isolated directories for all script paths
  export MOCK_BIN="${TEST_TEMP_DIR}/bin"
  export REVIEW_COUNTER_DIR="${TEST_TEMP_DIR}/counters"
  export REVIEW_PLAN_DIR="${TEST_TEMP_DIR}/plans"
  export REVIEW_LOG_DIR="${TEST_TEMP_DIR}/logs"

  mkdir -p "$MOCK_BIN" "$REVIEW_COUNTER_DIR" "$REVIEW_PLAN_DIR" "$REVIEW_LOG_DIR"

  # Prepend MOCK_BIN to PATH so mock engines are found first
  export PATH="${MOCK_BIN}:${PATH}"

  # Sane defaults: gemini engine, not disabled, not dry-run, 3 rounds, 20 total
  export REVIEW_ENGINE="gemini"
  export REVIEW_DISABLED="0"
  export REVIEW_DRY_RUN="0"
  export REVIEW_MAX_ROUNDS="3"
  export REVIEW_MAX_TOTAL_ROUNDS="20"

  # Zero retry delay in tests (production: 2s)
  export REVIEW_RETRY_DELAY=0

  # Zero capacity delay in tests (production: 25s) — prevents test hangs when
  # capacity-exhausted mock engines are used
  export REVIEW_CAPACITY_DELAY=0

  # High timeout for tests (mock engines return instantly)
  export REVIEW_ENGINE_TIMEOUT=90

  reset_leaky_env

  # Remove any residual degraded state file from previous tests
  rm -f "${REVIEW_COUNTER_DIR}/.gemini-degraded"
}

# reset_leaky_env
#   Unsets every env var a developer shell might export that would otherwise
#   reshape a test run. Kept as its own function, separate from common_setup,
#   for two reasons: the isolation becomes directly testable without paying
#   common_setup's side effects (re-entering it orphans the previous
#   TEST_TEMP_DIR, since `mktemp -d` reassigns it and common_teardown only
#   removes the last one — a caller that re-enters must rm the stale path
#   itself, as the "common_setup calls reset_leaky_env" case does), and adding
#   a fourth engine has one obvious place to register its vars. Pure unsets,
#   no side effects, safe to call repeatedly.
#
#   Whenever the production script grows a new `${SOME_VAR:-default}` read,
#   SOME_VAR belongs here.
reset_leaky_env() {
  # Recursive guard
  unset PLAN_REVIEW_RUNNING

  # Legacy env vars
  unset GEMINI_REVIEW_OFF
  unset GEMINI_DRY_RUN
  unset GEMINI_MAX_REVIEWS

  # REST fallback
  unset REVIEW_API_URL
  unset REVIEW_API_KEY

  # Hook budget override
  unset REVIEW_HOOK_BUDGET

  # Degraded state TTL override
  unset REVIEW_ENGINE_DEGRADE_TTL

  # Per-engine model ids. None of these change control flow today, so an
  # exported value breaks nothing at present — they are listed to keep this
  # function matching the rule stated above rather than drifting into "the
  # vars we happened to get burned by".
  unset AGY_MODEL
  unset CLAUDE_MODEL
  unset GEMINI_MODEL

  # codex engine. CODEX_BIN matters most: production resolves the binary as
  # "${CODEX_BIN:-codex}", so a developer who exports it sends the codex cases
  # at a REAL binary instead of MOCK_BIN/codex — which may hit the network,
  # run slow, or pass for the wrong reason. CODEX_MODEL breaks the
  # "empty → no -m flag" case outright.
  unset CODEX_BIN
  unset CODEX_MODEL

  # Mock codex behavior switches — scoped per-test via `export` in the cases
  # that need them. bats runs each test in its own subshell so they do not
  # normally leak across cases, but a developer shell that exported one would
  # silently reshape every codex case.
  unset MOCK_CODEX_NO_SECOND_DASHES
  unset MOCK_CODEX_EXTRA_BLANK
  unset MOCK_CODEX_STRICT_UTF8
}

common_teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

# --- Mock Engine Generators ---

# create_mock_engine <name> <output>
#   Creates an executable mock at MOCK_BIN/<name> that prints <output> to stdout.
#
#   JSON-aware (agy --output-format json): the production script calls agy with
#   `--output-format json` and unwraps the `response` field via awk. So this mock
#   auto-detects that flag and, when present, wraps <output> into agy's JSON
#   envelope (deliberately with raw newlines in the response value — mirroring
#   agy's actual NOT-well-formed JSON). Without the flag it prints <output> as
#   plain text (claude engine path / legacy). This one change keeps all existing
#   `create_mock_engine "agy" "<text>"` call sites working unchanged.
#
#   Also captures the invocation args to ${MOCK_BIN}/../.agy-args-<name> so tests
#   can assert whether `--conversation <id>` was passed (session-reuse behavior).
#   Fixed test conversation_id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
create_mock_engine() {
  local name="$1"
  local output="$2"
  local args_file="${MOCK_BIN}/../.agy-args-${name}"
  cat > "${MOCK_BIN}/${name}" << MOCK_EOF
#!/bin/bash
printf '%s\n' "\$*" > '${args_file}'
json_mode=0
case "\$*" in *"--output-format json"*) json_mode=1;; esac
if [ "\$json_mode" = "1" ]; then
  _out=\$(cat << 'ENGINE_OUTPUT'
${output}
ENGINE_OUTPUT
)
  # Escape backslash + double-quote for the JSON string; keep raw newlines
  # (agy's real JSON has unescaped newlines in "response" — that's the point).
  # Also HTML-safe-escape < > & into < > & — agy's real
  # backend (Go encoding/json default) always does this, so a fixture
  # containing a literal "<verdict>" tag must round-trip through the same
  # \u-escaped shape production traffic actually has, or this mock silently
  # stops exercising the awk unescaper's \u handling.
  _esc=\$(printf '%s' "\$_out" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g; s/</\\\\u003c/g; s/>/\\\\u003e/g; s/\&/\\\\u0026/g')
  printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"SUCCESS","response":"%s","usage":{"input_tokens":100,"total_tokens":200}}\n' "\$_esc"
else
  cat << 'ENGINE_OUTPUT'
${output}
ENGINE_OUTPUT
fi
MOCK_EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# agy_args <name>
#   Returns the captured invocation args string of the last call to mock <name>.
#   Empty if the mock was never invoked. Used to assert --conversation presence.
agy_args() {
  local name="$1"
  cat "${MOCK_BIN}/../.agy-args-${name}" 2>/dev/null || true
}

# create_failing_engine <name> <exit_code>
#   Creates a mock that always fails with the given exit code.
create_failing_engine() {
  local name="$1"
  local exit_code="$2"
  cat > "${MOCK_BIN}/${name}" << MOCK_EOF
#!/bin/bash
exit ${exit_code}
MOCK_EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# create_flaky_engine <name> <success_output> [first_behavior]
#   First call fails or returns empty, subsequent calls return success_output.
#   first_behavior: "exit" (default) → exit 1 on first call
#                   "empty" → return empty string on first call
#   State file lives in TEST_TEMP_DIR (per-test isolation, teardown auto-cleans).
create_flaky_engine() {
  local name="$1"
  local output="$2"
  local first_behavior="${3:-exit}"
  local state_file="${TEST_TEMP_DIR}/.flaky-${name}-state"
  local first_action="exit 1"
  [ "$first_behavior" != "empty" ] || first_action="exit 0"

  local args_file="${MOCK_BIN}/../.agy-args-${name}"
  cat > "${MOCK_BIN}/${name}" << MOCK_EOF
#!/bin/bash
printf '%s\n' "\$*" > '${args_file}'
if [ ! -f "${state_file}" ]; then
  touch "${state_file}"
  ${first_action}
fi
_out=\$(cat << 'ENGINE_OUTPUT'
${output}
ENGINE_OUTPUT
)
case "\$*" in
  *"--output-format json"*)
    _esc=\$(printf '%s' "\$_out" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g; s/</\\\\u003c/g; s/>/\\\\u003e/g; s/\&/\\\\u0026/g')
    printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"SUCCESS","response":"%s","usage":{"input_tokens":100,"total_tokens":200}}\n' "\$_esc" ;;
  *) printf '%s\n' "\$_out" ;;
esac
MOCK_EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# create_capacity_exhausted_engine <name>
#   Creates a mock engine that writes RESOURCE_EXHAUSTED to stderr and exits 1.
#   Triggers the capacity-detection branch in the retry loop.
create_capacity_exhausted_engine() {
  local name="$1"
  cat > "${MOCK_BIN}/${name}" << 'MOCK_EOF'
#!/bin/bash
echo '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","domain":"cloudcode-pa.googleapis.com"}}' >&2
exit 1
MOCK_EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# create_capacity_then_success_engine <name> <success_output>
#   First call: writes RESOURCE_EXHAUSTED to stderr and exits 1 (capacity-exhausted).
#   Subsequent calls: return success_output.
#   Used to verify that retry still fires when REST fallback is NOT configured.
create_capacity_then_success_engine() {
  local name="$1"
  local output="$2"
  local state_file="${TEST_TEMP_DIR}/.capacity-${name}-state"
  local args_file="${MOCK_BIN}/../.agy-args-${name}"
  cat > "${MOCK_BIN}/${name}" << MOCK_EOF
#!/bin/bash
printf '%s\n' "\$*" > '${args_file}'
if [ ! -f "${state_file}" ]; then
  touch "${state_file}"
  echo '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}' >&2
  exit 1
fi
_out=\$(cat << 'ENGINE_OUTPUT'
${output}
ENGINE_OUTPUT
)
case "\$*" in
  *"--output-format json"*)
    _esc=\$(printf '%s' "\$_out" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g; s/</\\\\u003c/g; s/>/\\\\u003e/g; s/\&/\\\\u0026/g')
    printf '{"conversation_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"SUCCESS","response":"%s","usage":{"input_tokens":100,"total_tokens":200}}\n' "\$_esc" ;;
  *) printf '%s\n' "\$_out" ;;
esac
MOCK_EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# create_mock_codex <output>
#   Creates an executable mock at MOCK_BIN/codex reproducing the real `codex
#   exec ... -o <file> -` contract: reads the prompt from stdin, writes
#   <output> (the final agent message) to the file named by the `-o` flag,
#   and echoes the REAL codex stderr shape to fd 2 (stdout is discarded by
#   the production script's `> /dev/null`, so anything meant to be visible
#   must go to stderr) — this is what the 1.6 diagnostic-backfill filter is
#   tested against:
#     line 1:      banner text
#     line 2:      -------- (first)
#     lines 3-10:  8 metadata lines
#     line 11:     -------- (second) — omit via MOCK_CODEX_NO_SECOND_DASHES=1
#     line 12:     user (extra blank line after it via MOCK_CODEX_EXTRA_BLANK=1)
#     then:        the prompt, cat'd back verbatim from stdin
#     then:        blank line + warning: + "ERROR: mock codex failure"
#   Captures "$*" to .agy-args-codex (same convention as create_mock_engine;
#   read it back with the existing `agy_args "codex"` helper). Always exits 0
#   — pair with create_failing_codex for non-zero-exit scenarios.
create_mock_codex() {
  local output="$1"
  local args_file="${MOCK_BIN}/../.agy-args-codex"
  cat > "${MOCK_BIN}/codex" << MOCK_EOF
#!/bin/bash
printf '%s\n' "\$*" > '${args_file}'
out_file=""
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "-o" ]; then out_file="\$arg"; fi
  prev="\$arg"
done
# Slurp stdin once so it can be validated before being echoed back.
_mock_stdin=\$(mktemp)
cat > "\$_mock_stdin"
# MOCK_CODEX_STRICT_UTF8=1 reproduces the real codex contract: it hard-rejects
# non-UTF-8 stdin instead of degrading. Byte-truncated CLAUDE.md content
# (head -c 3000 / -c 8000) can slice a multi-byte char in half, so without
# sanitation the real binary aborts with exactly this class of error.
if [ -n "\${MOCK_CODEX_STRICT_UTF8:-}" ] \\
   && ! iconv -f UTF-8 -t UTF-8 < "\$_mock_stdin" >/dev/null 2>&1; then
  echo "Failed to read prompt from stdin: input is not valid UTF-8 (invalid byte at offset 0). Convert it to UTF-8 and retry" >&2
  rm -f "\$_mock_stdin"
  exit 1
fi
{
  echo "codex-cli 0.0.0-mock"
  echo "--------"
  echo "workdir: /tmp/mock"
  echo "model: mock-model"
  echo "provider: mock"
  echo "approval: never"
  echo "sandbox: read-only"
  echo "reasoning effort: mock"
  echo "reasoning summaries: mock"
  echo "session: mock-session"
  if [ -z "\${MOCK_CODEX_NO_SECOND_DASHES:-}" ]; then
    echo "--------"
  fi
  echo "user"
  if [ -n "\${MOCK_CODEX_EXTRA_BLANK:-}" ]; then
    echo ""
  fi
  cat "\$_mock_stdin"
  echo ""
  echo "warning: mock warning line"
  echo "ERROR: mock codex failure"
} >&2
rm -f "\$_mock_stdin"
if [ -n "\$out_file" ]; then
  cat > "\$out_file" << 'OUTPUT_EOF'
${output}
OUTPUT_EOF
fi
exit 0
MOCK_EOF
  chmod +x "${MOCK_BIN}/codex"
}

# create_failing_codex <exit_code>
#   Same stderr shape as create_mock_codex (banner + verbatim stdin echo +
#   ERROR tail — honors the same MOCK_CODEX_NO_SECOND_DASHES / EXTRA_BLANK
#   knobs), but exits with the given code and never writes to the -o file
#   (mirrors a real crash: no final agent message was produced).
create_failing_codex() {
  local exit_code="$1"
  local args_file="${MOCK_BIN}/../.agy-args-codex"
  cat > "${MOCK_BIN}/codex" << MOCK_EOF
#!/bin/bash
printf '%s\n' "\$*" > '${args_file}'
{
  echo "codex-cli 0.0.0-mock"
  echo "--------"
  echo "workdir: /tmp/mock"
  echo "model: mock-model"
  echo "provider: mock"
  echo "approval: never"
  echo "sandbox: read-only"
  echo "reasoning effort: mock"
  echo "reasoning summaries: mock"
  echo "session: mock-session"
  if [ -z "\${MOCK_CODEX_NO_SECOND_DASHES:-}" ]; then
    echo "--------"
  fi
  echo "user"
  if [ -n "\${MOCK_CODEX_EXTRA_BLANK:-}" ]; then
    echo ""
  fi
  cat
  echo ""
  echo "warning: mock warning line"
  echo "ERROR: mock codex failure"
} >&2
exit ${exit_code}
MOCK_EOF
  chmod +x "${MOCK_BIN}/codex"
}

# create_mock_curl <response_body> [http_status]
#   Creates an executable mock curl at MOCK_BIN/curl that:
#   - writes <response_body> to the file specified by -o flag (curl -o behavior)
#   - prints http_status to stdout (simulating curl -w "%{http_code}" behavior)
#   http_status defaults to "200".
#   NOTE: writes the body VERBATIM (raw JSON, first char '{'). Post-SSE-migration
#   the production script treats a body whose first non-space char is '{' as a
#   non-SSE error object (error bypass), so this generator is now used for the
#   ERROR-path tests only. For success responses that must parse as an SSE
#   stream, use create_mock_curl_sse.
create_mock_curl() {
  local body="$1"
  local status="${2:-200}"
  cat > "${MOCK_BIN}/curl" << MOCK_EOF
#!/bin/bash
# Parse -o flag to find output file. Consume curl's streaming flags (added by
# the SSE migration) so their VALUES are not mistaken for positional args:
#   --no-buffer (no value); --speed-limit N / --speed-time N (one value each).
out_file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    --speed-limit|--speed-time) shift 2 ;;
    --no-buffer) shift ;;
    *)  shift ;;
  esac
done
if [ -n "\$out_file" ]; then
  cat > "\$out_file" << 'BODY'
${body}
BODY
fi
# Simulate curl -w "%{http_code}": write status to stdout (no trailing newline)
printf '%s' "${status}"
MOCK_EOF
  chmod +x "${MOCK_BIN}/curl"
}

# create_mock_curl_sse <content> [http_status]
#   Creates a mock curl that emits an OpenAI-compatible SSE stream carrying
#   <content> as the assistant message, mirroring the real endpoint the
#   production script now parses (data: {delta} frames + a data: [DONE]
#   terminator). Used for REST SUCCESS-path tests. <content> is JSON-escaped
#   via jq so embedded newlines/quotes survive into a single delta frame.
#   http_status defaults to "200".
create_mock_curl_sse() {
  local content="$1"
  local status="${2:-200}"
  # Build the SSE body: one content delta frame + the [DONE] terminator.
  # jq -c produces the escaped JSON object; prefix "data: " per SSE framing.
  local frame
  frame=$(jq -nc --arg c "$content" '{choices:[{delta:{content:$c}}]}')
  local sse_body
  sse_body="data: ${frame}

data: [DONE]
"
  cat > "${MOCK_BIN}/curl" << MOCK_EOF
#!/bin/bash
out_file=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    --speed-limit|--speed-time) shift 2 ;;
    --no-buffer) shift ;;
    *)  shift ;;
  esac
done
if [ -n "\$out_file" ]; then
  cat > "\$out_file" << 'BODY'
${sse_body}
BODY
fi
printf '%s' "${status}"
MOCK_EOF
  chmod +x "${MOCK_BIN}/curl"
}

# create_stalling_curl
#   Creates a mock curl that exits 28 (CURLE_OPERATION_TIMEDOUT) — simulates the
#   --speed-time stall watchdog firing mid-stream. Writes nothing to -o.
create_stalling_curl() {
  cat > "${MOCK_BIN}/curl" << 'MOCK_EOF'
#!/bin/bash
out_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    --speed-limit|--speed-time) shift 2 ;;
    --no-buffer) shift ;;
    *)  shift ;;
  esac
done
# Stall watchdog fired: no body, curl aborts with exit 28.
exit 28
MOCK_EOF
  chmod +x "${MOCK_BIN}/curl"
}

# create_failing_curl <exit_code>
#   Creates a mock curl that always fails with the given exit code.
create_failing_curl() {
  local exit_code="$1"
  cat > "${MOCK_BIN}/curl" << MOCK_EOF
#!/bin/bash
exit ${exit_code}
MOCK_EOF
  chmod +x "${MOCK_BIN}/curl"
}

# --- Input Construction ---

# build_input [key=value ...]
#   Constructs a JSON hook input. Defaults:
#     tool_name=ExitPlanMode, session_id=test-session, plan="Test plan content"
#   Override any field: build_input tool_name=Read session_id=abc plan="my plan"
build_input() {
  local tool_name="ExitPlanMode"
  local session_id="test-session"
  local plan="Test plan content"
  local cwd="/tmp"
  local transcript_path=""
  local plan_file_path=""

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      tool_name)       tool_name="$val" ;;
      session_id)      session_id="$val" ;;
      plan)            plan="$val" ;;
      cwd)             cwd="$val" ;;
      transcript_path) transcript_path="$val" ;;
      planFilePath)    plan_file_path="$val" ;;
    esac
  done

  # Build JSON with jq for proper escaping
  jq -n \
    --arg tn "$tool_name" \
    --arg sid "$session_id" \
    --arg p "$plan" \
    --arg cwd "$cwd" \
    --arg tp "$transcript_path" \
    --arg pfp "$plan_file_path" \
    '{
      tool_name: $tn,
      session_id: $sid,
      tool_input: ({ plan: $p } + (if $pfp != "" then { planFilePath: $pfp } else {} end)),
      cwd: $cwd,
      transcript_path: $tp
    }'
}

# build_input_no_plan [key=value ...]
#   Constructs input without a plan field in tool_input.
build_input_no_plan() {
  local tool_name="ExitPlanMode"
  local session_id="test-session"
  local cwd="/tmp"
  local plan_file_path=""
  local transcript_path=""

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      tool_name)       tool_name="$val" ;;
      session_id)      session_id="$val" ;;
      cwd)             cwd="$val" ;;
      planFilePath)    plan_file_path="$val" ;;
      transcript_path) transcript_path="$val" ;;
    esac
  done

  jq -n \
    --arg tn "$tool_name" \
    --arg sid "$session_id" \
    --arg cwd "$cwd" \
    --arg pfp "$plan_file_path" \
    --arg tp "$transcript_path" \
    '{
      tool_name: $tn,
      session_id: $sid,
      tool_input: (if $pfp != "" then { planFilePath: $pfp } else {} end),
      cwd: $cwd
    } + (if $tp != "" then { transcript_path: $tp } else {} end)'
}

# create_transcript_with_plan_file <plan_file_path> [transcript_filename]
#   Writes a minimal JSONL transcript containing a plan_mode attachment row that
#   references <plan_file_path> — mirrors the CC 2.1.x out-of-band plan contract.
#   Echoes the transcript path so callers can pass it as transcript_path.
create_transcript_with_plan_file() {
  local plan_file_path="$1"
  local fname="${2:-transcript.jsonl}"
  local transcript="${TEST_TEMP_DIR}/${fname}"
  # A couple of realistic rows + the plan_mode attachment carrying the path.
  jq -nc --arg p "$plan_file_path" \
    '{type:"user", message:{role:"user", content:"do the thing"}}' > "$transcript"
  jq -nc --arg p "$plan_file_path" \
    '{type:"attachment", attachment:{type:"plan_mode", planFilePath:$p, planExists:true}}' >> "$transcript"
  printf '%s' "$transcript"
}

# --- Plan File Helpers ---

# create_plan_file <content>
#   Writes a .md file in REVIEW_PLAN_DIR with the given content.
create_plan_file() {
  local content="$1"
  local filename="${2:-test-plan.md}"
  printf '%s' "$content" > "${REVIEW_PLAN_DIR}/${filename}"
}

# --- Approve Marker Helpers ---

# create_approve_marker [plan_content] [session_id]
#   Creates APPROVE_MARKER and writes the plan hash (mirrors plan_hash() in production).
#   Use ${1-default} (not ${1:-default}) so explicit empty string tests empty-marker compat.
create_approve_marker() {
  local plan_content="${1-Test plan content}"
  local session="${2:-test-session}"
  local marker="${REVIEW_COUNTER_DIR}/.review-approved-${session}"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$plan_content" | sha256sum | awk '{print $1}' > "$marker"
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$plan_content" | shasum -a 256 | awk '{print $1}' > "$marker"
  else
    printf '%s' "$plan_content" | cksum | awk '{print $1}' > "$marker"
  fi
}

# --- Counter Helpers ---

# get_counter_value [session_id]
#   Reads the ATTEMPT field from counter file (new format ATTEMPT:TOTAL).
#   Returns 0 if missing or unparseable.
get_counter_value() {
  local session="${1:-test-session}"
  local attempt total
  IFS=: read -r attempt total <<< "$(cat "${REVIEW_COUNTER_DIR}/.review-count-${session}" 2>/dev/null || echo "0:0")"
  echo "${attempt:-0}"
}

# get_total_rounds [session_id]
#   Reads the TOTAL_ROUNDS field from counter file (new format ATTEMPT:TOTAL).
#   Falls back to ATTEMPT for old single-number format.
get_total_rounds() {
  local session="${1:-test-session}"
  local attempt total
  IFS=: read -r attempt total <<< "$(cat "${REVIEW_COUNTER_DIR}/.review-count-${session}" 2>/dev/null || echo "0:0")"
  echo "${total:-$attempt}"
}

# set_counter_value <attempt> [session_id] [total_rounds]
#   Sets the counter file for the given session in ATTEMPT:TOTAL format.
set_counter_value() {
  local value="$1"
  local session="${2:-test-session}"
  local total="${3:-$value}"
  echo "${value}:${total}" > "${REVIEW_COUNTER_DIR}/.review-count-${session}"
}

# --- Run Hook ---

# run_hook
#   Feeds INPUT (must be set by caller or defaults to build_input) through the
#   hook script via stdin. Env vars must be exported BEFORE calling run_hook.
#   Sets: HOOK_STDOUT, HOOK_STDERR, HOOK_EXIT
run_hook() {
  local input="${INPUT:-$(build_input)}"

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  # Direct invocation — no eval, no exec indirection, no quote destruction.
  HOOK_STDOUT=$(bash "$HOOK_SCRIPT" <<< "$input" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# build_precompact_input [key=value ...]
#   Constructs a JSON PreCompact hook input.
#   Defaults: session_id=test-session
build_precompact_input() {
  local session_id="test-session"

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      session_id) session_id="$val" ;;
    esac
  done

  jq -n --arg sid "$session_id" '{"session_id": $sid}'
}

# run_precompact_hook
#   Feeds INPUT through the precompact-review.sh script via stdin.
#   Sets: HOOK_STDOUT, HOOK_STDERR, HOOK_EXIT
run_precompact_hook() {
  local input="${INPUT:-$(build_precompact_input)}"

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  HOOK_STDOUT=$(bash "$PRECOMPACT_SCRIPT" <<< "$input" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# run_hook_raw_stdin <literal_input>
#   Like run_hook but passes the literal string as-is to stdin, bypassing
#   the ${INPUT:-default} fallback. Use for empty or malformed input tests.
run_hook_raw_stdin() {
  local raw_input="$1"
  HOOK_STDOUT="" HOOK_STDERR="" HOOK_EXIT=0
  local stderr_file
  stderr_file=$(mktemp)
  HOOK_STDOUT=$(printf '%s' "$raw_input" | bash "$HOOK_SCRIPT" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Ack-Round Helpers ---

# run_hook_to_completion [session_id]
#   Runs hook. If APPROVE marker was written (ack-deny), runs again for ack-round.
#   Sets ACK_DENY_STDOUT with the ack-deny output if consumed.
run_hook_to_completion() {
  local session="${1:-test-session}"
  run_hook
  ACK_DENY_STDOUT=""
  # If the APPROVE marker was written, this was an ack-deny — run ack-round
  if [ -f "${REVIEW_COUNTER_DIR}/.review-approved-${session}" ]; then
    ACK_DENY_STDOUT="$HOOK_STDOUT"
    run_hook
  fi
}

# --- Dispatch File Helpers ---

# create_dispatch_file <session_id> <json_content>
#   Writes a dispatch JSON file to REVIEW_COUNTER_DIR/.dispatch-<session_id>.json.
create_dispatch_file() {
  local session="$1"
  local content="$2"
  printf '%s' "$content" > "${REVIEW_COUNTER_DIR}/.dispatch-${session}.json"
}

# build_agent_input [model=X] [subagent_type=Y] [tool_name=Agent] [session_id=S]
#   Constructs a JSON PreToolUse:Agent input.
build_agent_input() {
  local tool_name="Agent"
  local session_id="test-session"
  local model=""
  local subagent_type=""

  for arg in "$@"; do
    local key="${arg%%=*}"
    local val="${arg#*=}"
    case "$key" in
      tool_name)    tool_name="$val" ;;
      session_id)   session_id="$val" ;;
      model)        model="$val" ;;
      subagent_type) subagent_type="$val" ;;
    esac
  done

  # Build tool_input with only non-empty fields
  local tool_input
  if [ -n "$model" ] && [ -n "$subagent_type" ]; then
    tool_input=$(jq -n --arg m "$model" --arg st "$subagent_type" \
      '{model: $m, subagent_type: $st}')
  elif [ -n "$model" ]; then
    tool_input=$(jq -n --arg m "$model" '{model: $m}')
  elif [ -n "$subagent_type" ]; then
    tool_input=$(jq -n --arg st "$subagent_type" '{subagent_type: $st}')
  else
    tool_input='{}'
  fi

  jq -n \
    --arg tn "$tool_name" \
    --arg sid "$session_id" \
    --argjson ti "$tool_input" \
    '{tool_name: $tn, session_id: $sid, tool_input: $ti}'
}

# run_dispatch_check
#   Feeds INPUT through the dispatch-check.sh script via stdin.
#   Sets: HOOK_STDOUT, HOOK_STDERR, HOOK_EXIT
run_dispatch_check() {
  local input="${INPUT:-$(build_agent_input)}"

  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0

  local stderr_file
  stderr_file=$(mktemp)

  HOOK_STDOUT=$(bash "$DISPATCH_SCRIPT" <<< "$input" 2>"$stderr_file") || HOOK_EXIT=$?
  HOOK_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# --- Degraded State Helpers ---

# create_degraded_file [age_seconds]
#   Creates .gemini-degraded with a timestamp age_seconds in the past (default=0=fresh).
create_degraded_file() {
  local age="${1:-0}"
  local ts=$(( $(date +%s) - age ))
  printf '%s' "$ts" > "${REVIEW_COUNTER_DIR}/.gemini-degraded"
}

# assert_degraded_file_written
#   Verifies .gemini-degraded exists and contains a numeric timestamp.
assert_degraded_file_written() {
  local f="${REVIEW_COUNTER_DIR}/.gemini-degraded"
  [ -f "$f" ] || { echo "degraded file missing: $f"; return 1; }
  local ts; ts=$(cat "$f" 2>/dev/null)
  [[ "$ts" =~ ^[0-9]+$ ]] || { echo "non-numeric timestamp: '$ts'"; return 1; }
}

# --- Assertion Helpers ---

# assert_allowed
#   Verifies: exit 0, stdout does not contain a deny decision.
#   Permits empty stdout (guard exits) or allow JSON (APPROVE verdict).
assert_allowed() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  # stdout must NOT contain permissionDecision=deny
  if [ -n "$HOOK_STDOUT" ] && echo "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "Expected allow, got deny: $HOOK_STDOUT"
    return 1
  fi
}

# assert_approve_json
#   Verifies: exit 0, stdout is valid JSON with permissionDecision=allow.
assert_approve_json() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  # Must be valid JSON
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1 || {
    echo "stdout is not valid JSON: $HOOK_STDOUT"
    return 1
  }
  # Must contain permissionDecision=allow
  local decision
  decision=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')
  [ "$decision" = "allow" ] || {
    echo "Expected permissionDecision=allow, got: $decision"
    return 1
  }
  # Must carry hookEventName (framework rejects hookSpecificOutput without it)
  assert_hook_event_name
}

# assert_ack_approve_json
#   Verifies: exit 0, deny JSON with "APPROVED" in reason (ack-deny for APPROVE verdict).
assert_ack_approve_json() {
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"APPROVED"* ]] || {
    echo "Expected APPROVED in deny reason (ack-deny), got: $reason"
    return 1
  }
}

# assert_deny_json
#   Verifies: exit 0, stdout is valid JSON with permissionDecision=deny.
assert_deny_json() {
  [ "$HOOK_EXIT" -eq 0 ] || {
    echo "Expected exit 0, got $HOOK_EXIT"
    echo "stderr: $HOOK_STDERR"
    return 1
  }
  # Must be valid JSON
  echo "$HOOK_STDOUT" | jq . >/dev/null 2>&1 || {
    echo "stdout is not valid JSON: $HOOK_STDOUT"
    return 1
  }
  # Must contain permissionDecision=deny
  local decision
  decision=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecision')
  [ "$decision" = "deny" ] || {
    echo "Expected permissionDecision=deny, got: $decision"
    return 1
  }
  # Must carry hookEventName (framework rejects hookSpecificOutput without it)
  assert_hook_event_name
}

# assert_hook_event_name
#   Verifies hookSpecificOutput.hookEventName == "PreToolUse".
#   The Claude Code framework rejects any hookSpecificOutput missing this field
#   ("Hook JSON output validation failed"), so every emit path must carry it.
assert_hook_event_name() {
  local event_name
  event_name=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.hookEventName')
  [ "$event_name" = "PreToolUse" ] || {
    echo "Expected hookSpecificOutput.hookEventName=PreToolUse, got: '$event_name'"
    echo "stdout: $HOOK_STDOUT"
    return 1
  }
}

# assert_log_contains <pattern>
#   Verifies that the plan-review log file contains the given pattern.
assert_log_contains() {
  local pattern="$1"
  local log_file="${REVIEW_LOG_DIR}/plan-review.log"
  [ -f "$log_file" ] || { echo "Log file missing: $log_file"; return 1; }
  grep -q -- "$pattern" "$log_file" || { echo "Pattern '$pattern' not found in log:"; cat "$log_file"; return 1; }
}
