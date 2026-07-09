"""harvest_clients.responses - OpenAI Responses API client (gpt models).

gpt models get a dedicated path to the gateway's OpenAI Responses endpoint
(/responses) instead of /chat/completions. This is a KV-cache optimization,
not a capability upgrade: on this gateway (aapi.tbps.one, a new-api/one-api
aggregator that routes multiple upstream instances), repeated calls against
/chat/completions draw a random instance each time and essentially never
reuse a warm prefix cache, while /responses calls -- even called completely
statelessly (no previous_response_id, full messages resent every step,
exactly matching run_worker's calling pattern) -- land on the same instance
often enough to hit a growing prefix cache (see ADR-011 in the research
repo for the probe data). This is an *instance-affinity accident of this
particular gateway*, not a documented OpenAI Responses feature -- a
different gateway/provider must be re-probed before relying on it again.
Same complete(messages, tools) -> OpenAI-shaped-dict interface as
GatewayClient/AnthropicGatewayClient, so run_worker/judge_clusters/
run_judge_with_fallback stay unchanged; all protocol translation is
confined to the pure functions below.
"""

import contextlib
import json

from harvest_clients import base as _base


def _oai_tools_to_responses(tools):
    """OpenAI function-tool schema -> Responses API tool schema. Responses
    tools are flat ({"type":"function","name":...,"parameters":...}) unlike
    chat/completions' nested {"function": {...}} shape. Returns None for no
    tools (judge path passes tools=None) so the caller omits the field
    entirely, mirroring _oai_tools_to_anthropic."""
    if not tools:
        return None
    out = []
    for t in tools:
        fn = t.get("function", {})
        out.append({
            "type": "function",
            "name": fn.get("name", ""),
            "description": fn.get("description", ""),
            "parameters": fn.get("parameters", {"type": "object", "properties": {}}),
        })
    return out


def _oai_messages_to_responses(messages):
    """OpenAI chat-messages -> (instructions, input_items) for the Responses
    API. Mirrors _oai_messages_to_anthropic's role-by-role walk but targets
    Responses' flat item list instead of Anthropic's nested content blocks.

    - role=system   -> hoisted into `instructions` (concatenated; there is
      only ever one here in practice).
    - role=user     -> a message item with an input_text content block.
    - role=assistant -> a message item carrying any text (output_text block)
      followed by one function_call item per tool call. function_call
      `arguments` is passed through as-is: run_worker's outbound tool_calls
      already carry a JSON *string* (the same value the OpenAI chat-
      completions wire format uses), which is exactly what a Responses
      function_call item expects -- no json.loads/json.dumps round-trip
      needed here (unlike the Anthropic path, whose tool_use.input is a
      dict).
    - role=tool     -> a function_call_output item keyed by call_id
      (run_worker's tool_call_id becomes Responses' call_id).

    Unlike _oai_messages_to_anthropic there is no consecutive-turn merging
    requirement -- Responses' `input` is a flat item list with no
    alternating-role constraint, so tool results and user nudges are each
    emitted as their own item without a merge step."""
    instructions_parts = []
    items = []
    for msg in messages:
        role = msg.get("role")
        if role == "system":
            content = msg.get("content")
            if isinstance(content, str) and content:
                instructions_parts.append(content)
            continue
        if role == "tool":
            items.append({
                "type": "function_call_output",
                "call_id": msg.get("tool_call_id", ""),
                "output": msg.get("content", ""),
            })
            continue
        if role == "assistant":
            text = msg.get("content")
            if isinstance(text, str) and text:
                items.append({"role": "assistant", "content": [{"type": "output_text", "text": text}]})
            for tc in (msg.get("tool_calls") or []):
                fn = tc.get("function", {})
                items.append({
                    "type": "function_call",
                    "call_id": tc.get("id", ""),
                    "name": fn.get("name", ""),
                    "arguments": fn.get("arguments") or "{}",
                })
            continue
        # role == user (or unknown -> treat as user)
        content = msg.get("content")
        text = content if isinstance(content, str) else ""
        if text:
            items.append({"role": "user", "content": [{"type": "input_text", "text": text}]})
    instructions = "\n\n".join(instructions_parts) if instructions_parts else None
    return instructions, items


def _responses_resp_to_oai(resp):
    """Responses API response -> OpenAI chat-completions shape so
    _extract_message and the run_worker/judge_clusters loops read it
    unchanged (same contract as _anthropic_resp_to_oai).

    - `output` is a list of items; "message" items carry output_text content
      blocks (concatenated into `content`), "function_call" items become
      OpenAI tool_calls. `arguments` on a Responses function_call item is
      already a JSON string (same wire shape OpenAI chat/completions uses),
      so it is passed straight through -- no re-serialization, unlike the
      Anthropic path where tool_use.input is a dict needing json.dumps.
    - content is a string for a text-only reply (judge / final synthesis
      rely on a str here); it is None only when the turn is purely
      function_call, mirroring the Anthropic conversion's contract.
    - `status` is surfaced as finish_reason for observability (e.g.
      "incomplete" from a max_output_tokens truncation shows up instead of
      silently yielding half a JSON blob)."""
    output = resp.get("output") or []
    text_parts = []
    tool_calls = []
    for item in output:
        itype = item.get("type")
        if itype == "message":
            for blk in item.get("content") or []:
                if isinstance(blk, dict) and blk.get("type") in ("output_text", "text"):
                    text_parts.append(blk.get("text", ""))
        elif itype == "function_call":
            tool_calls.append({
                "id": item.get("call_id", ""),
                "type": "function",
                "function": {
                    "name": item.get("name", ""),
                    "arguments": item.get("arguments") or "{}",
                },
            })
    message = {"role": "assistant"}
    if tool_calls:
        message["content"] = "".join(text_parts) if text_parts else None
        message["tool_calls"] = tool_calls
    else:
        message["content"] = "".join(text_parts)
    return {
        "choices": [{"message": message, "finish_reason": resp.get("status")}],
        "usage": resp.get("usage", {}),
    }


class ResponsesGatewayClient:
    def __init__(self, base_url, api_key, model_id, timeout_s, max_output_tokens,
                 stream_enabled=False, ttft_timeout=None, inter_token_timeout=None,
                 stream_options=True):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model_id = model_id
        self.timeout_s = timeout_s
        # Mirrors AnthropicGatewayClient's max_tokens: Responses' equivalent
        # knob is max_output_tokens, and it is mandatory here for the same
        # reason max_tokens is mandatory on the Anthropic path -- a long
        # findings/judge JSON silently truncated by an unset/too-small output
        # cap surfaces as a parse_findings_json failure downstream, not as an
        # obvious "output was cut off" error. make_client_factory sources
        # this from the same limits.completion_max_tokens value used by the
        # Anthropic path (config-level single source of truth for "how big
        # can a completion be").
        self.max_output_tokens = max_output_tokens
        # Streaming opt-in, same contract as GatewayClient/AnthropicGatewayClient.
        self.stream_enabled = stream_enabled
        self.ttft_timeout = ttft_timeout
        self.inter_token_timeout = inter_token_timeout
        # Defaults to always-on (unlike GatewayClient's stream_options, which
        # defaults on but is meant to be flippable per-gateway) -- Responses
        # needs the final usage-bearing event to populate the returned
        # dict's "usage" key at all. Exposed as a constructor param anyway
        # so make_client_factory can wire it to the same
        # limits.gateway_stream_options escape hatch as GatewayClient, in
        # case a gateway ever rejects the field outright.
        self.stream_options = stream_options

    def _build_payload(self, messages, tools):
        instructions, input_items = _oai_messages_to_responses(messages)
        resp_tools = _oai_tools_to_responses(tools)
        payload = {
            "model": self.model_id,
            "input": input_items,
            "max_output_tokens": self.max_output_tokens,
        }
        if instructions is not None:
            payload["instructions"] = instructions
        if resp_tools is not None:
            payload["tools"] = resp_tools
        return payload

    def complete(self, messages, tools):
        if not self.stream_enabled:
            return self._complete_blocking(messages, tools)
        return self._complete_streaming(messages, tools)

    def _complete_blocking(self, messages, tools):
        payload = self._build_payload(messages, tools)
        url = self.base_url + "/responses"
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
        resp = _base._http_json_post_with_retry(url, payload, headers, self.timeout_s,
                                           transient_backoffs=_base._COMPLETION_RETRY_BACKOFFS)
        return _responses_resp_to_oai(resp)

    def _complete_streaming(self, messages, tools):
        payload = self._build_payload(messages, tools)
        payload["stream"] = True
        url = self.base_url + "/responses"
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}

        def attempt():
            with contextlib.closing(_base._http_stream_post(url, payload, headers, self.ttft_timeout)) as stream:
                resp = next(stream)
                sock = _base._get_raw_socket(resp)
                text_parts = []
                tool_calls = {}  # output_index -> {"id","type","function":{"name","arguments"}}
                finish_reason = None
                usage = {}
                seen_completed = False
                tightened = False
                for _event_type, data_str in stream:
                    if data_str is None or not data_str.strip():
                        continue
                    chunk = json.loads(data_str)  # JSONDecodeError -> outer retry loop
                    ctype = chunk.get("type", "")
                    if ctype == "error" or chunk.get("error"):
                        raise _base.StreamConnectionLost(f"error event mid-stream: {chunk}")
                    if ctype.endswith(".delta") and not tightened and sock is not None:
                        sock.settimeout(self.inter_token_timeout)
                        tightened = True
                    if ctype == "response.output_text.delta":
                        text_parts.append(chunk.get("delta", ""))
                    elif ctype in ("response.output_item.added", "response.output_item.done"):
                        item = chunk.get("item") or {}
                        if item.get("type") == "function_call":
                            idx = chunk.get("output_index", len(tool_calls))
                            slot = tool_calls.setdefault(idx, {
                                "id": "", "type": "function",
                                "function": {"name": "", "arguments": ""},
                            })
                            if item.get("call_id"):
                                slot["id"] = item["call_id"]
                            if item.get("name"):
                                slot["function"]["name"] = item["name"]
                            if ctype == "response.output_item.done" and item.get("arguments"):
                                # Consolidated final arguments string, in case
                                # any function_call_arguments.delta frames
                                # were missed or coalesced upstream.
                                slot["function"]["arguments"] = item["arguments"]
                    elif ctype == "response.function_call_arguments.delta":
                        idx = chunk.get("output_index")
                        if idx is not None:
                            slot = tool_calls.setdefault(idx, {
                                "id": "", "type": "function",
                                "function": {"name": "", "arguments": ""},
                            })
                            slot["function"]["arguments"] += chunk.get("delta", "")
                    elif ctype in ("response.completed", "response.incomplete"):
                        seen_completed = True
                        response_obj = chunk.get("response") or {}
                        usage = response_obj.get("usage") or {}
                        finish_reason = response_obj.get("status")

            if not seen_completed:
                raise _base.StreamConnectionLost("stream ended without a response.completed/incomplete event")

            message = {"role": "assistant"}
            ordered_tool_calls = [tool_calls[i] for i in sorted(tool_calls)]
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
