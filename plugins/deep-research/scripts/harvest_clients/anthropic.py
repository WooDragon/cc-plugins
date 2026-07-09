"""harvest_clients.anthropic - Anthropic-native /messages client (claude models).

claude models get a dedicated path to the gateway's Anthropic-native
/messages endpoint (not the OpenAI-compatible /chat/completions used for
gemini/gpt) so that prompt caching (cache_control) actually takes effect --
the OpenAI-compat conversion in the gateway silently drops cache_control,
so claude via that path never caches. This client speaks the exact same
complete(messages, tools) -> OpenAI-shaped-dict interface as GatewayClient,
so run_worker / judge_clusters stay identical; all protocol translation is
confined to the pure functions below.
"""

import contextlib
import json
import socket
import time
import urllib.error

from harvest_clients import base as _base


def _anthropic_post_with_retry(url, payload, headers, timeout, transient_backoffs=None):
    """Retry wrapper for the Anthropic /messages endpoint. Unlike the OpenAI
    gateway path, a non-transient 4xx (400/401/403/404) is NOT retried -- a
    malformed request body fails identically on a resend, so we surface the
    Anthropic error body immediately for debugging. Only 429/408/5xx and
    network-layer failures follow the transient backoff schedule. HTTPError
    is caught before URLError (its parent) so the status-bearing case isn't
    swallowed."""
    backoffs = transient_backoffs if transient_backoffs is not None else _base._GATEWAY_RETRY_BACKOFFS_TRANSIENT
    attempt = 0
    while True:
        attempt += 1
        try:
            return _base._http_json_post(url, payload, headers, timeout)
        except urllib.error.HTTPError as e:
            status = e.code
            transient = status in (429, 408) or 500 <= status < 600
            body = _base._read_http_error_body(e)
            if not transient:
                raise RuntimeError(f"Anthropic HTTP {status}: {body}") from e
            if attempt - 1 >= len(backoffs):
                raise RuntimeError(f"Anthropic HTTP {status} after {attempt} attempts: {body}") from e
            time.sleep(backoffs[attempt - 1])
        except (urllib.error.URLError, socket.timeout, TimeoutError, json.JSONDecodeError) as e:
            if attempt - 1 >= len(backoffs):
                raise RuntimeError(f"Anthropic network error after {attempt} attempts: {e}") from e
            time.sleep(backoffs[attempt - 1])


def _oai_tools_to_anthropic(tools):
    """OpenAI function-tool schema -> Anthropic tool schema. Returns None when
    there are no tools (judge path passes tools=None) so the caller can omit
    the field entirely rather than send tools:null / tools:[]."""
    if not tools:
        return None
    out = []
    for t in tools:
        fn = t.get("function", {})
        out.append({
            "name": fn.get("name", ""),
            "description": fn.get("description", ""),
            "input_schema": fn.get("parameters", {"type": "object", "properties": {}}),
        })
    return out


def _assistant_to_anthropic_content(msg):
    """Convert one OpenAI assistant message into an Anthropic assistant
    content-block list: leading text block (only if non-empty -- Anthropic
    rejects empty text blocks) followed by one tool_use block per tool_call.
    A plain-text assistant turn (no tool_calls) returns its string content
    directly. tool_call arguments are JSON strings (json.dumps output on the
    outbound side); json.loads restores the dict for tool_use.input, tolerant
    of a malformed/empty string."""
    tool_calls = msg.get("tool_calls") or []
    text = msg.get("content")
    if not tool_calls:
        # Plain assistant answer. Anthropic needs a non-empty content; fall
        # back to a single space if the model somehow returned empty (should
        # not happen on a no-tool turn, but never emit an empty text block).
        return text if isinstance(text, str) and text else " "
    blocks = []
    if isinstance(text, str) and text:
        blocks.append({"type": "text", "text": text})
    for tc in tool_calls:
        fn = tc.get("function", {})
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        blocks.append({
            "type": "tool_use",
            "id": tc.get("id", ""),
            "name": fn.get("name", ""),
            "input": args,
        })
    return blocks


def _oai_messages_to_anthropic(messages):
    """Split an OpenAI-style messages list into (system, anthropic_messages).

    - role=system  -> hoisted into the top-level `system` (concatenated if
      more than one; there is only ever one here in practice).
    - role=user    -> passed through (content is str or a content-block list).
    - role=assistant -> text + tool_use blocks (see helper).
    - role=tool    -> a tool_result block; *consecutive* tool messages are
      merged into a single user turn (Anthropic requires all tool_result
      blocks answering the previous assistant's tool_use to live in one user
      message). run_worker appends one role=tool per tool_call, so this run of
      tool messages must collapse into one user turn.

    Adjacent same-role user turns are also merged, mirroring the gateway's
    "no two consecutive user messages" constraint that append_or_merge_user
    already relies on."""
    system_parts = []
    anth = []
    i = 0
    n = len(messages)
    while i < n:
        msg = messages[i]
        role = msg.get("role")
        if role == "system":
            content = msg.get("content")
            if isinstance(content, str):
                system_parts.append(content)
            elif isinstance(content, list):
                for blk in content:
                    if isinstance(blk, dict) and blk.get("type") == "text":
                        system_parts.append(blk.get("text", ""))
            i += 1
            continue
        if role == "tool":
            # Collapse the maximal run of consecutive tool messages into one
            # user turn of tool_result blocks.
            results = []
            while i < n and messages[i].get("role") == "tool":
                tmsg = messages[i]
                results.append({
                    "type": "tool_result",
                    "tool_use_id": tmsg.get("tool_call_id", ""),
                    "content": tmsg.get("content", ""),
                })
                i += 1
            _append_user_blocks(anth, results)
            continue
        if role == "assistant":
            anth.append({"role": "assistant", "content": _assistant_to_anthropic_content(msg)})
            i += 1
            continue
        # role == user (or unknown -> treat as user)
        _append_user_blocks(anth, msg.get("content"))
        i += 1
    system = "\n\n".join(p for p in system_parts if p) if system_parts else None
    return system, anth


def _append_user_blocks(anth, content):
    """Append `content` as a user turn, merging into a trailing user turn if
    present (Anthropic rejects two consecutive user messages). `content` may
    be a str, a single block dict, or a list of blocks; the merged turn is
    normalized to a block list when mixing shapes."""
    if isinstance(content, list):
        incoming = content
    elif isinstance(content, dict):
        incoming = [content]
    elif content:  # non-empty string
        incoming = [{"type": "text", "text": content}]
    else:  # None or "" -> contribute nothing; never fabricate an empty text
        incoming = []  # block (Anthropic rejects empty text blocks -> 400)
    if not incoming:
        return
    if anth and anth[-1]["role"] == "user":
        existing = anth[-1]["content"]
        if isinstance(existing, str):
            existing = [{"type": "text", "text": existing}] if existing else []
        elif isinstance(existing, dict):
            existing = [existing]
        existing.extend(incoming)
        anth[-1]["content"] = existing
    else:
        anth.append({"role": "user", "content": incoming})


def _anthropic_resp_to_oai(resp):
    """Anthropic /messages response -> OpenAI chat-completions shape so
    _extract_message (resp["choices"][0]["message"]) and the run_worker /
    judge_clusters loops read it unchanged.

    - text blocks are concatenated into `content`.
    - tool_use blocks become OpenAI tool_calls (arguments re-serialized to a
      JSON string via json.dumps, matching what the OpenAI path produces).
    - content is a string for a text-only reply (judge / final synthesis rely
      on a str here); it is None only when the turn is purely tool_use, which
      run_worker's `message.get("content") or ""` and the inbound converter
      both tolerate.
    - stop_reason is surfaced as finish_reason for observability (e.g.
      max_tokens truncation shows up instead of silently yielding half a
      JSON blob)."""
    content_blocks = resp.get("content") or []
    text_parts = []
    tool_calls = []
    for blk in content_blocks:
        btype = blk.get("type")
        if btype == "text":
            text_parts.append(blk.get("text", ""))
        elif btype == "tool_use":
            tool_calls.append({
                "id": blk.get("id", ""),
                "type": "function",
                "function": {
                    "name": blk.get("name", ""),
                    "arguments": json.dumps(blk.get("input", {}), ensure_ascii=False),
                },
            })
    message = {"role": "assistant"}
    if tool_calls:
        message["content"] = "".join(text_parts) if text_parts else None
        message["tool_calls"] = tool_calls
    else:
        message["content"] = "".join(text_parts)
    return {
        "choices": [{"message": message, "finish_reason": resp.get("stop_reason")}],
        "usage": resp.get("usage", {}),
    }


class AnthropicGatewayClient:
    def __init__(self, base_url, api_key, model_id, timeout_s, max_tokens, effort=None,
                 stream_enabled=False, ttft_timeout=None, inter_token_timeout=None):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model_id = model_id
        self.timeout_s = timeout_s
        self.max_tokens = max_tokens
        # effort=None preserves the exact wire behavior from before this
        # field existed (no output_config sent at all, provider default
        # applies -- currently "high"). make_client_factory is the one place
        # that supplies a non-None value (config-driven, default "medium");
        # the class itself stays decoupled from that policy choice so it can
        # be unit-tested with either shape. See ADR-011 (research repo) --
        # this is a deliberate global default lowering, not "old behavior
        # preserved for old configs".
        self.effort = effort
        # Streaming opt-in, same contract as GatewayClient's stream_enabled --
        # default False keeps every existing (positional-args-only) call site
        # on the old non-streaming behavior untouched.
        self.stream_enabled = stream_enabled
        self.ttft_timeout = ttft_timeout
        self.inter_token_timeout = inter_token_timeout

    def _build_payload(self, messages, tools):
        system, anth_messages = _oai_messages_to_anthropic(messages)
        anth_tools = _oai_tools_to_anthropic(tools)
        system = _inject_cache_control(system, anth_tools, anth_messages)
        payload = {
            "model": self.model_id,
            "max_tokens": self.max_tokens,
            "messages": anth_messages,
        }
        if system is not None:
            payload["system"] = system
        if anth_tools is not None:
            payload["tools"] = anth_tools
        if self.effort is not None:
            payload["output_config"] = {"effort": self.effort}
        return payload

    def complete(self, messages, tools):
        if not self.stream_enabled:
            return self._complete_blocking(messages, tools)
        return self._complete_streaming(messages, tools)

    def _complete_blocking(self, messages, tools):
        payload = self._build_payload(messages, tools)
        url = self.base_url + "/messages"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        }
        resp = _anthropic_post_with_retry(url, payload, headers, self.timeout_s,
                                          transient_backoffs=_base._COMPLETION_RETRY_BACKOFFS)
        return _anthropic_resp_to_oai(resp)

    def _complete_streaming(self, messages, tools):
        payload = self._build_payload(messages, tools)
        payload["stream"] = True
        url = self.base_url + "/messages"
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        }

        def attempt():
            with contextlib.closing(_base._http_stream_post(url, payload, headers, self.ttft_timeout)) as stream:
                resp = next(stream)
                sock = _base._get_raw_socket(resp)
                text_parts = []
                tool_calls = []  # list, in content_block index order
                current_tool_input_json = {}  # block_index -> accumulated partial_json
                finish_reason = None
                usage = {}
                seen_message_stop = False
                tightened = False
                for event_type, data_str in stream:
                    if data_str is None or not data_str.strip():
                        continue
                    chunk = json.loads(data_str)  # JSONDecodeError -> outer retry loop
                    if event_type == "error":
                        raise _base.StreamConnectionLost(f"error event mid-stream: {chunk}")
                    if event_type == "message_start":
                        msg_usage = (chunk.get("message") or {}).get("usage") or {}
                        if msg_usage:
                            usage["input_tokens"] = msg_usage.get("input_tokens")
                    elif event_type == "content_block_start":
                        block = chunk.get("content_block") or {}
                        if block.get("type") == "tool_use":
                            idx = chunk.get("index", len(tool_calls))
                            tool_calls.append((idx, {
                                "id": block.get("id", ""),
                                "type": "function",
                                "function": {"name": block.get("name", ""), "arguments": ""},
                            }))
                            current_tool_input_json[idx] = ""
                    elif event_type == "content_block_delta":
                        delta = chunk.get("delta") or {}
                        dtype = delta.get("type")
                        is_content_delta = dtype in ("text_delta", "thinking_delta", "input_json_delta")
                        if is_content_delta and not tightened and sock is not None:
                            sock.settimeout(self.inter_token_timeout)
                            tightened = True
                        if dtype == "text_delta":
                            text_parts.append(delta.get("text", ""))
                        elif dtype == "input_json_delta":
                            idx = chunk.get("index")
                            if idx in current_tool_input_json:
                                current_tool_input_json[idx] += delta.get("partial_json", "")
                    elif event_type == "message_delta":
                        delta_usage = chunk.get("usage") or {}
                        if delta_usage:
                            usage["output_tokens"] = delta_usage.get("output_tokens")
                        raw_stop_reason = (chunk.get("delta") or {}).get("stop_reason")
                        if raw_stop_reason:
                            finish_reason = raw_stop_reason
                    elif event_type == "message_stop":
                        seen_message_stop = True

            if not seen_message_stop:
                raise _base.StreamConnectionLost("stream ended without a message_stop event")

            # Fold each tool call's accumulated partial_json into its
            # function.arguments, matching _anthropic_resp_to_oai's
            # json.dumps(tool_use.input)-as-a-string contract.
            ordered_tool_calls = []
            for idx, tc in tool_calls:
                raw_json = current_tool_input_json.get(idx, "")
                try:
                    parsed_input = json.loads(raw_json) if raw_json else {}
                except json.JSONDecodeError:
                    parsed_input = {}
                tc["function"]["arguments"] = json.dumps(parsed_input, ensure_ascii=False)
                ordered_tool_calls.append(tc)

            message = {"role": "assistant"}
            if ordered_tool_calls:
                message["content"] = "".join(text_parts) if text_parts else None
                message["tool_calls"] = ordered_tool_calls
            else:
                message["content"] = "".join(text_parts)
            return {
                "choices": [{"message": message, "finish_reason": finish_reason}],
                "usage": usage,
            }

        return _base._run_stream_attempt_with_retry(attempt)


_CACHE_CONTROL = {"type": "ephemeral"}
# Anthropic allows at most 4 cache breakpoints. We use 3: tools tail, system
# tail, and the last message content block (the moving conversation
# breakpoint). All use the default 5-minute TTL rather than the "1h" option:
# a worker's agentic loop and the judge call all complete well inside 5
# minutes, so the longer TTL buys nothing here while its 2x write cost and
# the unsettled beta-header requirement for "ttl":"1h" (the docs don't state
# whether it needs an anthropic-beta header) would only add risk. A
# breakpoint caches the ENTIRE prefix up to and including its block, in the
# fixed order tools -> system -> messages, so these three points let every
# turn read the whole static prefix (tools+system) plus all prior history
# from cache and pay full price only for the newest increment.


def _mark_block_list_tail(blocks):
    """Attach cache_control to the last cacheable (dict) block in a list.
    Anthropic rejects cache_control on an empty text block, so skip a tail
    block that is an empty-text block. No-op if there is no dict block."""
    for blk in reversed(blocks):
        if not isinstance(blk, dict):
            continue
        if blk.get("type") == "text" and not blk.get("text"):
            continue
        blk["cache_control"] = dict(_CACHE_CONTROL)
        return True
    return False


def _mark_message_tail(messages):
    """Move the conversation breakpoint onto the last content block of the
    last message. String content is promoted to a one-text-block list so the
    marker has somewhere to live (Anthropic accepts either shape); an empty
    string is left untouched (nothing cacheable, and an empty text block is
    rejected)."""
    if not messages:
        return
    last = messages[-1]
    content = last.get("content")
    if isinstance(content, str):
        if not content:
            return
        last["content"] = [{"type": "text", "text": content, "cache_control": dict(_CACHE_CONTROL)}]
    elif isinstance(content, list) and content:
        _mark_block_list_tail(content)


def _inject_cache_control(system, tools, messages):
    """Attach cache_control breakpoints in place for maximal prefix caching.

    cache_control cannot ride on a bare string, so a non-empty system string
    is promoted here into a single cache-marked text block list (Anthropic
    accepts system as either a string or a block list); an already-block-list
    system just gets its tail marked. Because this rewrites system, the value
    is RETURNED and AnthropicGatewayClient.complete must send the returned
    system in the payload -- tools and messages are mutated in place. An empty
    or None system is returned untouched (nothing cacheable).

    Breakpoints: tools tail + system tail (static prefix) + last message
    content block (see _mark_message_tail). Returns the (possibly rewritten)
    system value."""
    if tools:
        _mark_block_list_tail(tools)
    if isinstance(system, str) and system:
        system = [{"type": "text", "text": system, "cache_control": dict(_CACHE_CONTROL)}]
    elif isinstance(system, list) and system:
        _mark_block_list_tail(system)
    _mark_message_tail(messages)
    # Known limit: only the single moving message breakpoint is used, so if
    # one turn ever appended >=20 content blocks (Anthropic's incremental-
    # cache lookback window) the prior breakpoint would fall out of window and
    # that one turn would miss cache. In this pipeline a turn adds ~2 blocks
    # (one tool_use + one tool_result), so the window is never approached; a
    # 4th "anchor" breakpoint would only pay off with heavy parallel tool use
    # and is deliberately omitted to keep the strategy simple.
    return system
