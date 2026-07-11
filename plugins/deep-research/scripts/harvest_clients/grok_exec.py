"""harvest_clients.grok_exec - shared grok CLI execution + parsing primitives.

Leaf module: never imports harvest.py or any harvest_search/harvest_fetch
sibling (see harvest_clients/base.py's module docstring -- "harvest.py
imports from harvest_clients, never the reverse"). Two callers share this
module: harvest_clients.grok_cli's GrokCliClient (a full panel-member client)
and harvest_search.social's grok-x social-search backend. Both invoke the
same local `grok` CLI, just with different prompts/rules -- this module is
the one place that owns the subprocess/retry/parse mechanics so neither
caller duplicates them.

`--output-format plain` (not `json`) is used deliberately: plain mode prints
grok's raw final-turn text directly, with no envelope. Measured against the
`json` envelope + `--json-schema` combination this replaces, plain mode is
more reliable in practice -- the json envelope's `text` field sometimes
carries the model's raw thinking prose instead of the structured answer, and
--json-schema has been observed to provoke a doubled "{}{...}" output (an
empty object followed by the real one) rather than a single clean object.
Schema conformance is now enforced entirely through prompt/rules text, and
parse_embedded_json()'s multi-object salvage logic below exists specifically
to tolerate the doubled-object failure mode without a second grok round-trip.
"""

import json
import os
import subprocess
import tempfile
import time

# Fixed-backoff transient retry, same pattern as harvest_clients.base's HTTP
# retries (no tenacity dependency). len(DEFAULT_RETRY_BACKOFFS) == 2 sleeps
# between 3 total attempts (see run_grok_plain's attempts = len(retry_backoffs) + 1).
DEFAULT_RETRY_BACKOFFS = (2, 5)


def run_grok_plain(prompt_text, model_id, effort, timeout, rules, retry_backoffs=DEFAULT_RETRY_BACKOFFS):
    """Invoke the grok CLI once (with bounded retry on transient failure) in
    --output-format plain and return its raw stdout text.

    The prompt is written to a fresh NamedTemporaryFile, flushed and fsynced
    *inside* the `with` block (so a mid-write exception still closes the fd
    via the context manager) -- the subprocess call itself happens *outside*
    the `with` block, once the file is guaranteed fully written and closed.
    The temp file is always removed afterward via the outer try/finally,
    regardless of how the with-block or subprocess call exits.

    FileNotFoundError (grok not installed / not on PATH) is not retried --
    a missing binary does not heal itself between attempts -- and is raised
    immediately so the caller can fail fast rather than burn the whole
    backoff schedule. subprocess.TimeoutExpired and a non-zero exit are
    transient and retried up to len(retry_backoffs) + 1 attempts; once
    exhausted, a RuntimeError carrying a stderr/timeout summary is raised."""
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".txt") as f:
            temp_path = f.name
            f.write(prompt_text)
            f.flush()
            os.fsync(f.fileno())
        cmd = [
            "grok", "--prompt-file", temp_path, "-m", model_id, "--effort", effort,
            "--sandbox", "read-only", "--output-format", "plain",
        ]
        if rules:
            cmd += ["--rules", rules]
        last_err = None
        attempts = len(retry_backoffs) + 1
        for attempt in range(attempts):
            try:
                proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True,
                                       text=True, timeout=timeout)
            except subprocess.TimeoutExpired:
                last_err = f"grok: timed out after {timeout}s"
                if attempt < attempts - 1:
                    time.sleep(retry_backoffs[attempt])
                    continue
                raise RuntimeError(f"{last_err} (after {attempts} attempts)")
            if proc.returncode != 0:
                detail = (proc.stderr or "").strip()[:500]
                last_err = f"grok: exited with code {proc.returncode}" + (f": {detail}" if detail else "")
                if attempt < attempts - 1:
                    time.sleep(retry_backoffs[attempt])
                    continue
                raise RuntimeError(f"{last_err} (after {attempts} attempts)")
            return proc.stdout or ""
        # Unreachable (the loop always either returns or raises), kept only
        # so a future refactor that changes the loop shape fails loudly
        # instead of silently falling through with no return value.
        raise RuntimeError(last_err or "grok: failed for an unknown reason")
    finally:
        if temp_path:
            try:
                os.unlink(temp_path)
            except OSError:
                pass


def parse_embedded_json(text):
    """Salvage one merged dict out of grok's plain-text stdout, tolerant of
    the "{}{...}" doubled-object failure mode (see module docstring) and of
    stray non-JSON prose before/between/after the object(s). Always returns
    a dict (never a str) -- {} when nothing usable was found.

    Strategy:
      1. Fast path: the whole trimmed text is itself one JSON object -- the
         normal case when plain mode behaves and the prompt's "output ONLY
         one JSON object" instruction is followed exactly.
      2. Fallback: scan forward from each '{' with json.JSONDecoder.raw_decode,
         collecting every top-level value that decodes (skipping over
         anything in between that doesn't), then merge:
           - each decoded dict is a candidate object;
           - each decoded list has its dict-typed elements folded in as
             candidates too (a top-level `[{...}]` is not discarded);
           - non-dict, non-list decoded values are ignored.
         "results" / "claims" arrays are extend()-ed across every candidate
         (list-typed, non-list values dropped, non-dict elements filtered
         out) rather than overwritten -- this is what makes the doubled-
         "{}{...}" case recoverable. Scalar fields lock to the first
         non-empty value seen and are never clobbered by a later null/empty/
         wrong-type value from a subsequent candidate.
    """
    stripped = text.strip()
    try:
        obj = json.loads(stripped)
        if isinstance(obj, dict):
            return obj
    except (json.JSONDecodeError, ValueError):
        pass

    idx = stripped.find("{")
    if idx == -1:
        return {}

    decoder = json.JSONDecoder()
    candidates = []
    while idx != -1:
        try:
            obj, end = decoder.raw_decode(stripped, idx)
        except (json.JSONDecodeError, ValueError):
            idx = stripped.find("{", idx + 1)
            continue
        if isinstance(obj, dict):
            candidates.append(obj)
        elif isinstance(obj, list):
            candidates.extend(item for item in obj if isinstance(item, dict))
        # Advance past this decoded value's end, skipping whitespace, so the
        # next search resumes after it rather than re-scanning inside it.
        next_idx = end
        while next_idx < len(stripped) and stripped[next_idx].isspace():
            next_idx += 1
        idx = stripped.find("{", next_idx)

    if not candidates:
        return {}

    merged_results = []
    merged_claims = []
    locked_scalars = {}
    for obj in candidates:
        res = obj.get("results")
        if isinstance(res, list):
            merged_results.extend(item for item in res if isinstance(item, dict))
        claims = obj.get("claims")
        if isinstance(claims, list):
            merged_claims.extend(item for item in claims if isinstance(item, dict))
        for key, value in obj.items():
            if key in ("results", "claims"):
                continue
            if key not in locked_scalars and value:
                locked_scalars[key] = value

    merged = dict(locked_scalars)
    if merged_results:
        merged["results"] = merged_results
    if merged_claims:
        merged["claims"] = merged_claims
    return merged
