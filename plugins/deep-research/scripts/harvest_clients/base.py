"""harvest_clients.base - shared HTTP/SSE plumbing for the four gateway clients.

Pure protocol layer: no provider-specific knowledge lives here. This module
must never import from harvest.py (harvest.py imports from harvest_clients,
never the reverse).
"""

import gzip
import http.client
import json
import socket
import ssl
import time
import urllib.error
import urllib.request


def _read_http_error_body(e):
    """Best-effort read of an HTTPError's response body so Anthropic's own
    error diagnostics (e.g. {"error":{"message":"messages: roles must
    alternate ..."}}) survive into the raised exception instead of being
    swallowed as a bare status code."""
    try:
        return e.read().decode("utf-8", "replace")[:800]
    except Exception:
        return "<error body unavailable>"


def _maybe_decompress(raw, resp):
    encoding = (resp.headers.get("Content-Encoding") or "").lower()
    if encoding == "gzip":
        try:
            return gzip.decompress(raw)
        except OSError:
            return raw
    return raw


def _http_json_post(url, payload, headers, timeout):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        raw = _maybe_decompress(raw, resp)
        return json.loads(raw.decode("utf-8"))


# Retry schedule for the gateway chat/completions call only (shared by the
# panel loop and the judge) -- other backends keep their existing
# degrade-to-next-backend behavior and are not retried here.
_GATEWAY_RETRY_BACKOFFS_TRANSIENT = (5, 15)  # 429/408/5xx: up to 2 retries
_GATEWAY_RETRY_BACKOFFS_OTHER_4XX = (5,)     # other 4xx (401/403/404...): 1 retry
_COMPLETION_RETRY_BACKOFFS = (2, 5, 15, 30)  # 4 retries, 52s total backoff


def _http_json_post_with_retry(url, payload, headers, timeout, transient_backoffs=None):
    """Bounded retry around _http_json_post for transient gateway failures.
    Classification is fixed on the first failure's status code and the
    matching backoff schedule is followed to exhaustion -- no lock is held
    across this function or its sleeps, so worker/judge threads never block
    each other while backing off.

    Two failure shapes share one retry loop: an HTTP response with a status
    code (HTTPError -- classified transient/4xx by status), and a network-
    layer failure with no status code at all (URLError/socket.timeout --
    always treated as transient, same as a 5xx). HTTPError must be caught
    before URLError since urllib raises HTTPError as a URLError subclass;
    catching the parent first would swallow the status-code-bearing case."""
    backoffs = None
    attempt = 0
    while True:
        attempt += 1
        try:
            return _http_json_post(url, payload, headers, timeout)
        except urllib.error.HTTPError as e:
            status = e.code
            if backoffs is None:
                transient = status in (429, 408) or 500 <= status < 600
                backoffs = (transient_backoffs if transient_backoffs is not None else _GATEWAY_RETRY_BACKOFFS_TRANSIENT) if transient else _GATEWAY_RETRY_BACKOFFS_OTHER_4XX
            retries_done = attempt - 1
            if retries_done >= len(backoffs):
                raise RuntimeError(f"HTTP {status} after {attempt} attempts") from e
            time.sleep(backoffs[retries_done])
        except (urllib.error.URLError, socket.timeout, TimeoutError, json.JSONDecodeError) as e:
            # No status code (connection refused/reset, DNS failure, read
            # timeout, ...) -- always transient, same schedule as 429/5xx.
            if backoffs is None:
                backoffs = transient_backoffs if transient_backoffs is not None else _GATEWAY_RETRY_BACKOFFS_TRANSIENT
            retries_done = attempt - 1
            if retries_done >= len(backoffs):
                raise RuntimeError(f"network error after {attempt} attempts: {e}") from e
            time.sleep(backoffs[retries_done])


# ---------------------------------------------------------------------------
# SSE streaming infrastructure (fail-fast watchdog for completion calls)
#
# Pure protocol layer: _http_stream_post knows nothing about any provider's
# event shapes, only the generic SSE wire format (event:/data:/comment lines
# terminated by a blank line). Each of the four completion clients' complete()
# consumes this generator and layers its own provider-specific frame parsing
# and logical-end detection on top -- see AnthropicGatewayClient.complete /
# ResponsesGatewayClient.complete / GeminiNativeGatewayClient.complete /
# GatewayClient.complete.
# ---------------------------------------------------------------------------

class StreamIdleTimeout(RuntimeError):
    """Inter-token or TTFT (time-to-first-token) timeout -- transient,
    retryable under the same backoff schedule as a network-layer failure."""


class StreamConnectionLost(RuntimeError):
    """Mid-stream connection drop (socket reset, truncated read, TLS error)
    -- transient, retryable."""


class StreamNotSupportedError(RuntimeError):
    """Server returned HTTP 200 but the body is not an SSE stream (e.g. a
    plain application/json error payload) -- permanent, callers must NOT
    retry this as a transient stream failure. The escape-hatch config flags
    (limits.anthropic_stream etc.) exist precisely so an operator can flip
    back to the non-streaming path if a gateway turns out not to support
    streaming at all."""


def _get_raw_socket(resp):
    """Best-effort extraction of the underlying socket from an
    http.client.HTTPResponse so a caller can settimeout() it once streaming
    is under way (tightening from a generous TTFT timeout to a tighter
    inter-token timeout). Tries the shapes seen across CPython's http.client/
    ssl-wrapped-socket implementations; returns None (never raises) if none
    match, so a caller that can't get a socket degrades to "no watchdog
    tightening" rather than crashing."""
    for attr_chain in [('fp', 'raw', '_sock'), ('fp', '_sock'), ('sock',)]:
        obj = resp
        for attr in attr_chain:
            obj = getattr(obj, attr, None)
            if obj is None:
                break
        else:
            if hasattr(obj, 'settimeout'):
                return obj
    return None


# Exceptions that can surface from resp.readline()/resp.read() once the
# connection is open -- collapsed into StreamIdleTimeout at the readline
# call site (the caller distinguishes idle-timeout from connection-lost by
# *when* in the frame lifecycle the exception occurred, not by exception
# type -- both socket.timeout from an inter-token settimeout() and a genuine
# mid-read connection reset raise through this same set on CPython).
_STREAM_READ_EXCEPTIONS = (
    http.client.IncompleteRead, urllib.error.URLError, ConnectionResetError,
    TimeoutError, socket.timeout, ssl.SSLError,
)


def _http_stream_post(url, payload, headers, initial_timeout):
    """POST `payload` and yield parsed Server-Sent-Events frames.

    Usage::

        stream = _http_stream_post(url, payload, headers, timeout)
        resp = next(stream)            # underlying HTTPResponse
        sock = _get_raw_socket(resp)   # may be None
        for event_type, data_str in stream:
            ...

    Yields:
        - First value: the raw HTTPResponse object, so the caller can obtain
          the underlying socket via _get_raw_socket() before consuming any
          frames.
        - Every value after that: an ``(event_type, data_str)`` tuple, one
          per complete SSE frame (a run of ``event:``/``data:`` lines
          terminated by a blank line; multiple ``data:`` lines in one frame
          are newline-joined per the SSE spec). A bare comment line (leading
          ``:``) yields ``(None, None)`` immediately as a heartbeat -- it
          does not participate in frame buffering.

    Raises:
        urllib.error.HTTPError: the initial connection attempt got a non-2xx
            response. Re-raised as-is (not wrapped) so a caller's retry loop
            can classify it exactly like `_http_json_post_with_retry` /
            `_anthropic_post_with_retry` already do (429/408/5xx transient,
            other 4xx not) -- the response body is stashed on
            `e.stream_error_body` (best-effort, mirroring
            `_read_http_error_body`'s pattern) since `e.read()` can only be
            called once.
        StreamNotSupportedError: the connection succeeded (HTTP 200) but the
            response Content-Type is not text/event-stream (e.g. the gateway
            fell back to a plain JSON error body) -- permanent, do not retry
            as a stream failure.
        StreamConnectionLost: reading the non-SSE response body itself failed
            at the socket level, or a mid-stream error surfaces at the
            protocol layer.
        StreamIdleTimeout: a readline() call raised a socket-level exception
            while consuming the event stream (covers both "no bytes for N
            seconds" once the caller has tightened the socket timeout, and a
            genuine connection drop -- the caller's retry loop treats both as
            transient either way).

    The whole body runs inside a ``with`` block around the connection-opening
    call below, so a consumer that stops iterating early (GeneratorExit, e.g.
    from ``contextlib.closing``) still closes the underlying connection via
    the context manager's __exit__.
    """
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=initial_timeout) as resp:
            content_type = (resp.headers.get("Content-Type") or "").lower()
            if "text/event-stream" not in content_type:
                try:
                    body = resp.read(500)
                except _STREAM_READ_EXCEPTIONS as e:
                    raise StreamConnectionLost(
                        f"failed reading non-stream response body "
                        f"(Content-Type={content_type!r}): {e}"
                    ) from e
                body_text = body.decode("utf-8", errors="replace")
                raise StreamNotSupportedError(
                    f"expected text/event-stream, got Content-Type={content_type!r}: {body_text}"
                )

            yield resp

            event_type = None
            data_lines = []
            while True:
                try:
                    raw_line = resp.readline()
                except _STREAM_READ_EXCEPTIONS as e:
                    raise StreamIdleTimeout(f"stream read failed: {e}") from e

                if raw_line == b"":
                    # EOF -- flush a buffered partial frame (if any), then stop.
                    if data_lines or event_type is not None:
                        yield (event_type, "\n".join(data_lines))
                    return

                line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")

                if line == "":
                    # Blank line terminates the current frame (SSE spec) --
                    # yield unconditionally, even if the frame is empty (a
                    # stray keepalive blank line); callers already skip
                    # empty/whitespace-only data_str per the shared
                    # consumption contract.
                    yield (event_type, "\n".join(data_lines))
                    event_type = None
                    data_lines = []
                    continue

                if line.startswith(":"):
                    # Comment/heartbeat line -- does not belong to any frame.
                    yield (None, None)
                    continue

                if line.startswith("event:"):
                    event_type = line[len("event:"):].strip()
                    continue

                if line.startswith("data:"):
                    # SSE spec: strip at most one leading space after "data:".
                    field_value = line[len("data:"):]
                    if field_value.startswith(" "):
                        field_value = field_value[1:]
                    data_lines.append(field_value)
                    continue
                # Other SSE fields (id:, retry:) carry no meaning for any of
                # the four providers this module speaks to -- ignored.
    except urllib.error.HTTPError as e:
        # Re-raise (not wrapped in RuntimeError) so the caller's retry loop
        # can classify by e.code exactly like the non-streaming paths do.
        # Stash the body since e.read() is single-shot and the caller may
        # want it for a final error message after retries are exhausted.
        e.stream_error_body = _read_http_error_body(e)
        raise


# Exceptions a streaming completion attempt can raise that the retry loop
# below treats as transient (same set specified for all four streaming
# clients): idle/connection failures at the SSE layer, raw socket-level
# timeouts (a caller's own settimeout() can raise these directly, not just
# via _STREAM_READ_EXCEPTIONS inside _http_stream_post), and a malformed
# frame body (JSONDecodeError) -- one garbled chunk is worth a resend, not a
# hard failure. urllib.error.HTTPError is handled separately (by status
# code) rather than blanket-listed here.
_STREAM_RETRYABLE_EXCEPTIONS = (
    StreamIdleTimeout, StreamConnectionLost, socket.timeout, TimeoutError,
    urllib.error.URLError, json.JSONDecodeError, ssl.SSLError,
)


def _run_stream_attempt_with_retry(attempt_fn, backoffs=_COMPLETION_RETRY_BACKOFFS):
    """Generic bounded-retry wrapper shared by all four streaming complete()
    paths. `attempt_fn()` performs exactly one full attempt -- open the
    stream, consume it to completion, assemble and return the OpenAI-shaped
    result dict -- and this wrapper retries the whole attempt on any
    transient failure, following the same fixed backoff schedule the
    non-streaming paths use.

    StreamNotSupportedError is deliberately not caught here: it means the
    gateway returned HTTP 200 with a non-SSE body (e.g. plain JSON), which no
    amount of retrying fixes -- it must propagate so the caller can fall back
    via its escape-hatch config flag (limits.anthropic_stream etc.) instead
    of being silently swallowed as "just another transient error".

    HTTPError is classified by status like `_http_json_post_with_retry` /
    `_anthropic_post_with_retry` already do: 429/408/5xx are transient and
    retried; any other 4xx fails immediately (a malformed request resends
    identically)."""
    attempt = 0
    while True:
        attempt += 1
        try:
            return attempt_fn()
        except urllib.error.HTTPError as e:
            status = e.code
            transient = status in (429, 408) or 500 <= status < 600
            body = getattr(e, "stream_error_body", None) or _read_http_error_body(e)
            if not transient:
                raise RuntimeError(f"HTTP {status} opening stream: {body}") from e
            if attempt - 1 >= len(backoffs):
                raise RuntimeError(f"HTTP {status} opening stream after {attempt} attempts: {body}") from e
            time.sleep(backoffs[attempt - 1])
        except _STREAM_RETRYABLE_EXCEPTIONS as e:
            if attempt - 1 >= len(backoffs):
                raise RuntimeError(f"stream failed after {attempt} attempts: {e}") from e
            time.sleep(backoffs[attempt - 1])
