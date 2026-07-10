"""harvest_clients.gemini - Gemini-native generateContent client."""

import contextlib
import json
import uuid

from harvest_clients import base as _base


def _gemini_generate_content_url(base_url, model_id):
    """Derive the Gemini-native generateContent URL from the gateway's
    OpenAI-compat base_url. Unlike _search_gemini_grounding's urlsplit
    (scheme://netloc only, which silently drops any path prefix between the
    origin and '/v1'), this strips only a trailing '/v1' *suffix* so a
    base_url like 'https://gw.corp.com/ai-proxy/v1' keeps its '/ai-proxy'
    prefix intact."""
    base = base_url.rstrip("/")
    if base.endswith("/v1"):
        base = base[: -len("/v1")]
    return f"{base}/v1beta/models/{model_id}:generateContent"


def _gemini_stream_generate_content_url(base_url, model_id):
    """Streaming counterpart of _gemini_generate_content_url -- same base-url
    normalization, but the streamGenerateContent method with alt=sse so the
    gateway (assumed to speak the standard Gemini REST surface) emits
    Server-Sent Events instead of a single buffered JSON array."""
    base = base_url.rstrip("/")
    if base.endswith("/v1"):
        base = base[: -len("/v1")]
    return f"{base}/v1beta/models/{model_id}:streamGenerateContent?alt=sse"


def _oai_tools_to_gemini(tools):
    """OpenAI function-tool schema -> Gemini tool schema (a single entry
    carrying all function declarations). Returns None for no tools (judge
    path passes tools=None) so the caller omits the field entirely,
    mirroring _oai_tools_to_anthropic/_oai_tools_to_responses."""
    if not tools:
        return None
    declarations = []
    for t in tools:
        fn = t.get("function", {})
        declarations.append({
            "name": fn.get("name", ""),
            "description": fn.get("description", ""),
            "parameters": fn.get("parameters", {"type": "object", "properties": {}}),
        })
    return [{"functionDeclarations": declarations}]


def _append_gemini_user_parts(contents, parts):
    """Append `parts` as a Gemini user turn, merging into a trailing user
    turn if present. Gemini enforces alternating roles the same way
    Anthropic does, so a run of consecutive tool results (each becoming a
    functionResponse part) and any immediately-following user nudge must
    collapse into one turn rather than producing back-to-back user turns."""
    if not parts:
        return
    if contents and contents[-1]["role"] == "user":
        contents[-1]["parts"].extend(parts)
    else:
        contents.append({"role": "user", "parts": parts})


def _gemini_tool_response_payload(content):
    """Parse an OpenAI tool message's `content` string into the dict Gemini's
    functionResponse.response requires. content is JSON-decoded when
    possible; a non-JSON string, or JSON that decodes to a non-dict (list/
    bool/number), is wrapped as {"result": <value>} so the final payload is
    always a dict."""
    try:
        parsed = json.loads(content)
    except (json.JSONDecodeError, TypeError):
        return {"result": content}
    if not isinstance(parsed, dict):
        return {"result": parsed}
    return parsed


def _oai_messages_to_gemini(messages):
    """OpenAI chat-messages -> (system_instruction, contents) for the Gemini
    generateContent API. Mirrors _oai_messages_to_anthropic's role-by-role
    walk but targets Gemini's parts/role shape.

    - role=system    -> hoisted into `system_instruction` (multiple system
      messages are concatenated with '\\n\\n', never overwritten by a later
      one). None when there is no system message.
    - role=assistant -> role "model"; text content becomes a text part,
      each tool_call becomes a functionCall part. When the internal
      tool_call dict carries a `thought_signature` (captured by
      _gemini_resp_to_oai off the response's sibling `thoughtSignature`
      key), it is echoed back as a `thoughtSignature` sibling key on the
      rebuilt part; when absent it is omitted, never fabricated.
    - role=tool      -> OpenAI's tool message carries no function name, but
      Gemini's functionResponse requires one, so a forward pass records
      {tool_call_id: function_name} from every assistant tool_call seen so
      far; a tool message whose tool_call_id has no recorded name means the
      upstream message sequence itself violates the OpenAI contract, and
      that is raised explicitly rather than papered over with an empty name.
    - role=user/other -> role "user", text part.

    Consecutive user-role turns (tool results, and tool results immediately
    followed by a user nudge) are merged via _append_gemini_user_parts,
    mirroring _oai_messages_to_anthropic's tool-result collapsing."""
    system_parts = []
    contents = []
    call_id_to_name = {}
    for msg in messages:
        role = msg.get("role")
        if role == "system":
            content = msg.get("content")
            if isinstance(content, str) and content:
                system_parts.append(content)
            continue
        if role == "assistant":
            parts = []
            text = msg.get("content")
            if isinstance(text, str) and text:
                parts.append({"text": text})
            for tc in (msg.get("tool_calls") or []):
                fn = tc.get("function", {})
                name = fn.get("name", "")
                call_id_to_name[tc.get("id")] = name
                try:
                    args = json.loads(fn.get("arguments") or "{}")
                except json.JSONDecodeError:
                    args = {}
                part = {"functionCall": {"name": name, "args": args}}
                if tc.get("thought_signature") is not None:
                    part["thoughtSignature"] = tc["thought_signature"]
                parts.append(part)
            if not parts:
                parts = [{"text": ""}]
            contents.append({"role": "model", "parts": parts})
            continue
        if role == "tool":
            call_id = msg.get("tool_call_id")
            name = call_id_to_name.get(call_id)
            if name is None:
                raise ValueError(
                    f"tool message references unknown tool_call_id={call_id!r} "
                    "(no matching assistant tool_call seen yet)"
                )
            payload = _gemini_tool_response_payload(msg.get("content", ""))
            _append_gemini_user_parts(contents, [{"functionResponse": {"name": name, "response": payload}}])
            continue
        # role == user (or unknown -> treat as user)
        content = msg.get("content")
        text = content if isinstance(content, str) else ""
        if text:
            _append_gemini_user_parts(contents, [{"text": text}])
    system_instruction = None
    if system_parts:
        system_instruction = {"parts": [{"text": "\n\n".join(system_parts)}]}
    return system_instruction, contents


def _collect_gemini_parts(parts, text_parts, tool_calls, floating_sigs):
    """Walk a list of Gemini content parts, accumulating text into
    `text_parts`, functionCall parts into `tool_calls`, and any orphaned
    `thoughtSignature` into `floating_sigs`. Shared by the blocking parser
    (_gemini_resp_to_oai) and the streaming accumulator
    (_complete_streaming) so both place signatures identically.

    The signature is read INDEPENDENTLY of the text/functionCall branching.
    Gemini 3 attaches it as a sibling key on the first functionCall part in
    the aggregated (blocking) case, but a streamGenerateContent response may
    instead deliver the thinking-state signature on a separate `thought`
    part or a trailing empty-text part (per the official thought-signatures
    guidance -- "the model may return the thought signature in a part with an
    empty text content part"). The old `if "text" ... elif "functionCall"`
    walk silently dropped any such part, so the signature never reached the
    tool_call and the replayed functionCall was rejected server-side as a
    corrupted/absent signature on the next turn. Capturing the signature per
    part regardless of the part's other keys is what makes streaming behave
    like the blocking path, which never saw a detached signature because the
    server had already aggregated it onto the functionCall part.

    A signature that rides its own functionCall part is attached to that
    tool_call immediately (`sig = None` so it is not also double-counted as
    floating); a signature with no functionCall in the same part is left in
    `floating_sigs` for _attach_floating_sigs to place after the full part/
    frame walk completes."""
    for part in parts:
        sig = part.get("thoughtSignature")
        if "functionCall" in part:
            fc = part["functionCall"]
            tc = {
                "id": f"call_{uuid.uuid4().hex[:8]}",
                "type": "function",
                "function": {
                    "name": fc.get("name", ""),
                    "arguments": json.dumps(fc.get("args", {}), ensure_ascii=False),
                },
            }
            if sig is not None:
                tc["thought_signature"] = sig
                sig = None
            tool_calls.append(tc)
        elif "text" in part:
            text_parts.append(part["text"])
        if sig is not None:
            floating_sigs.append(sig)


def _attach_floating_sigs(tool_calls, floating_sigs):
    """Bind a thought signature that arrived detached from its functionCall
    part back onto the first tool_call -- and ONLY the first.

    The Gemini 3 contract is strict: within one step the signature belongs to
    the *first* functionCall part; subsequent parallel calls legitimately
    carry none, and the server rejects a replay that puts a signature on a
    call that should not have one. So a detached signature (delivered on a
    separate `thought`/empty-text part, as streamGenerateContent may do) is
    bound to tool_calls[0] only, and only when tool_calls[0] does not already
    carry its own sibling signature. It is never spread across slots 1..N in
    arrival order -- doing so would fabricate a signature in exactly the
    position the contract forbids.

    This is a no-op in the aggregated/blocking case, where every signature
    already rode its functionCall part so floating_sigs is empty. Leftover
    floating signatures (more than one, or one when slot 0 is already signed,
    or any when there is no functionCall at all -- a pure-text turn) are
    dropped: the run_worker loop never replays a pure-text turn to continue
    tool calling, and the contract wants at most one signature on slot 0."""
    if not floating_sigs or not tool_calls:
        return
    if "thought_signature" not in tool_calls[0]:
        tool_calls[0]["thought_signature"] = floating_sigs[0]


def _gemini_resp_to_oai(resp):
    """Gemini generateContent response -> OpenAI chat-completions shape so
    _extract_message and the run_worker/judge_clusters loops read it
    unchanged (same contract as _anthropic_resp_to_oai/_responses_resp_to_oai).

    Two layers of safety-interception defense, both must not raise:
    - prompt-level: an empty/missing `candidates` list (the whole prompt was
      blocked) is checked *before* any `candidates[0]` indexing. The block
      reason from promptFeedback is preserved in the returned usage dict
      (diagnostic only; no consumer reads it today) rather than discarded.
    - candidate-level: a candidate with finishReason=="SAFETY" or no
      "content" key (HTTP 200, but nothing to read) degrades to empty
      content/no tool_calls via .get() chains, never a bare KeyError.

    finish_reason is semantically mapped, not passed through raw: any
    parsed tool_calls force "tool_calls" (highest priority, regardless of
    the raw finishReason); otherwise "STOP"->"stop", "MAX_TOKENS"->"length",
    and any other raw value is lowercased and passed through as-is (never
    forged into "stop").

    Gemini 3-series thinking models attach an opaque `thoughtSignature` that
    must be echoed back verbatim on replay (as `thought_signature`, snake_case
    per this codebase's internal dict convention) or the next turn's replayed
    functionCall is rejected server-side. In the aggregated response the
    signature rides the first functionCall part as a sibling key; capture is
    delegated to _collect_gemini_parts / _attach_floating_sigs (shared with
    the streaming path) so a signature the server ever delivers on a separate
    part is still bound to its tool_call rather than dropped. It is per-part
    optional -- on parallel function calls only the first carries a signature
    -- so absence means the key is omitted entirely, never fabricated as
    None."""
    candidates = resp.get("candidates")
    if not candidates:
        block_reason = (resp.get("promptFeedback") or {}).get("blockReason")
        usage = dict(resp.get("usageMetadata") or {})
        usage["prompt_block_reason"] = block_reason
        message = {"role": "assistant", "content": "", "tool_calls": None}
        return {"choices": [{"message": message, "finish_reason": "prompt_blocked"}], "usage": usage}

    candidate = candidates[0]
    raw_finish = candidate.get("finishReason")
    content_parts = (candidate.get("content") or {}).get("parts") or []
    text_parts = []
    tool_calls = []
    floating_sigs = []
    _collect_gemini_parts(content_parts, text_parts, tool_calls, floating_sigs)
    _attach_floating_sigs(tool_calls, floating_sigs)
    message = {"role": "assistant", "content": "".join(text_parts)}
    if tool_calls:
        message["tool_calls"] = tool_calls
        finish_reason = "tool_calls"
    else:
        message["tool_calls"] = None
        if raw_finish == "STOP":
            finish_reason = "stop"
        elif raw_finish == "MAX_TOKENS":
            finish_reason = "length"
        elif raw_finish:
            finish_reason = raw_finish.lower()
        else:
            finish_reason = None
    return {
        "choices": [{"message": message, "finish_reason": finish_reason}],
        "usage": resp.get("usageMetadata", {}),
    }


class GeminiNativeGatewayClient:
    def __init__(self, base_url, api_key, model_id, timeout_s, max_output_tokens,
                 stream_enabled=False, ttft_timeout=None, inter_token_timeout=None):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model_id = model_id
        self.timeout_s = timeout_s
        self.max_output_tokens = max_output_tokens
        # Streaming opt-in, same contract as the other three clients.
        self.stream_enabled = stream_enabled
        self.ttft_timeout = ttft_timeout
        self.inter_token_timeout = inter_token_timeout

    def _build_payload(self, messages, tools):
        system_instruction, contents = _oai_messages_to_gemini(messages)
        gemini_tools = _oai_tools_to_gemini(tools)
        payload = {
            "contents": contents,
            "generationConfig": {"maxOutputTokens": self.max_output_tokens},
        }
        if system_instruction is not None:
            payload["systemInstruction"] = system_instruction
        if gemini_tools is not None:
            payload["tools"] = gemini_tools
        return payload

    def complete(self, messages, tools):
        if not self.stream_enabled:
            return self._complete_blocking(messages, tools)
        return self._complete_streaming(messages, tools)

    def _complete_blocking(self, messages, tools):
        payload = self._build_payload(messages, tools)
        url = _gemini_generate_content_url(self.base_url, self.model_id)
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
        resp = _base._http_json_post_with_retry(url, payload, headers, self.timeout_s,
                                           transient_backoffs=_base._COMPLETION_RETRY_BACKOFFS)
        return _gemini_resp_to_oai(resp)

    def _complete_streaming(self, messages, tools):
        # No "stream": true on the payload -- Gemini switches to SSE purely
        # via the :streamGenerateContent?alt=sse URL, unlike the other three
        # providers which flip a payload field on the same endpoint.
        payload = self._build_payload(messages, tools)
        url = _gemini_stream_generate_content_url(self.base_url, self.model_id)
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}

        def attempt():
            with contextlib.closing(_base._http_stream_post(url, payload, headers, self.ttft_timeout)) as stream:
                resp = next(stream)
                sock = _base._get_raw_socket(resp)
                text_parts = []
                tool_calls = []
                # Accumulated across ALL frames, not per-frame: a thinking-
                # state thoughtSignature can arrive on a `thought`/empty-text
                # part in a frame after the functionCall part's frame, so
                # detached signatures are collected stream-wide and bound to
                # their tool_calls only once every frame has been consumed.
                floating_sigs = []
                usage = {}
                finish_reason = None
                prompt_block_reason = None
                seen_logical_end = False
                tightened = False
                for _event_type, data_str in stream:
                    if data_str is None or not data_str.strip():
                        continue
                    # Each SSE data frame is itself a complete
                    # generateContent-shaped response object (not a delta
                    # envelope like the other three providers) -- accumulate
                    # its parts and keep only the latest usageMetadata, which
                    # the API reports cumulatively.
                    chunk = json.loads(data_str)  # JSONDecodeError -> outer retry loop
                    candidates = chunk.get("candidates")
                    if not candidates:
                        prompt_block_reason = (chunk.get("promptFeedback") or {}).get("blockReason")
                        if prompt_block_reason:
                            raise _base.StreamConnectionLost(f"prompt blocked mid-stream: {prompt_block_reason}")
                        continue
                    if chunk.get("usageMetadata"):
                        usage = chunk["usageMetadata"]
                    candidate = candidates[0]
                    content_parts = (candidate.get("content") or {}).get("parts") or []
                    if content_parts and not tightened and sock is not None:
                        sock.settimeout(self.inter_token_timeout)
                        tightened = True
                    _collect_gemini_parts(content_parts, text_parts, tool_calls, floating_sigs)
                    raw_finish = candidate.get("finishReason")
                    if raw_finish:
                        seen_logical_end = True
                        if tool_calls:
                            finish_reason = "tool_calls"
                        elif raw_finish == "STOP":
                            finish_reason = "stop"
                        elif raw_finish == "MAX_TOKENS":
                            finish_reason = "length"
                        else:
                            finish_reason = raw_finish.lower()

            if not seen_logical_end:
                raise _base.StreamConnectionLost("stream ended without a candidate finishReason")

            # Determine finish_reason after all frames consumed (tool_calls
            # may arrive in frames after finishReason — see ADR-013 review #4).
            if tool_calls:
                finish_reason = "tool_calls"

            # Bind any detached signatures to their functionCalls only now,
            # after the whole stream is consumed -- a signature frame can
            # follow its functionCall frame.
            _attach_floating_sigs(tool_calls, floating_sigs)

            message = {"role": "assistant", "content": "".join(text_parts)}
            if tool_calls:
                message["tool_calls"] = tool_calls
            return {
                "choices": [{"message": message, "finish_reason": finish_reason}],
                "usage": usage,
            }

        return _base._run_stream_attempt_with_retry(attempt)
