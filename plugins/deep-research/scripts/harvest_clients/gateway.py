"""harvest_clients.gateway - OpenAI-compatible chat/completions client."""

import contextlib
import json

from harvest_clients import base as _base


# ---------------------------------------------------------------------------
# Chat client (OpenAI-compatible gateway)
# ---------------------------------------------------------------------------

class GatewayClient:
    def __init__(self, base_url, api_key, model_id, timeout_s,
                 stream_enabled=False, ttft_timeout=None, inter_token_timeout=None,
                 stream_options=True):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model_id = model_id
        self.timeout_s = timeout_s
        # Streaming is opt-in (default False) so every existing call site --
        # tests included -- keeps the exact non-streaming behavior it had
        # before this parameter existed. make_client_factory is the one place
        # that turns it on from config (limits.gateway_stream).
        self.stream_enabled = stream_enabled
        self.ttft_timeout = ttft_timeout
        self.inter_token_timeout = inter_token_timeout
        # Some OpenAI-compatible gateways only emit a final usage-bearing
        # chunk (choices: []) if stream_options.include_usage is requested;
        # others reject an unrecognized field outright, hence the escape
        # hatch (limits.gateway_stream_options) rather than always-on.
        self.stream_options = stream_options

    def complete(self, messages, tools):
        if not self.stream_enabled:
            url = self.base_url + "/chat/completions"
            payload = {"model": self.model_id, "messages": messages}
            if tools:
                payload["tools"] = tools
            headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}
            return _base._http_json_post_with_retry(url, payload, headers, self.timeout_s,
                                               transient_backoffs=_base._COMPLETION_RETRY_BACKOFFS)
        return self._complete_streaming(messages, tools)

    def _complete_streaming(self, messages, tools):
        url = self.base_url + "/chat/completions"
        payload = {"model": self.model_id, "messages": messages, "stream": True}
        if tools:
            payload["tools"] = tools
        if self.stream_options:
            payload["stream_options"] = {"include_usage": True}
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}

        def attempt():
            with contextlib.closing(_base._http_stream_post(url, payload, headers, self.ttft_timeout)) as stream:
                resp = next(stream)
                sock = _base._get_raw_socket(resp)
                text_parts = []
                tool_calls = {}  # index -> {"id","type","function":{"name","arguments"}}
                finish_reason = None
                usage = {}
                seen_done = False
                tightened = False
                for _event_type, data_str in stream:
                    if data_str is None or not data_str.strip():
                        continue
                    if data_str == "[DONE]":
                        seen_done = True
                        break
                    chunk = json.loads(data_str)  # JSONDecodeError -> outer retry loop
                    if chunk.get("error"):
                        raise _base.StreamConnectionLost(f"error frame mid-stream: {chunk['error']}")
                    if chunk.get("usage"):
                        usage = chunk["usage"]
                    choices = chunk.get("choices") or []
                    if not choices:
                        # A choices:[] chunk carries only usage (the
                        # include_usage final chunk) -- nothing else to do.
                        continue
                    choice = choices[0]
                    delta = choice.get("delta") or {}
                    if choice.get("finish_reason"):
                        finish_reason = choice["finish_reason"]
                    has_content = bool(delta.get("content")) or bool(delta.get("tool_calls"))
                    if has_content and not tightened and sock is not None:
                        sock.settimeout(self.inter_token_timeout)
                        tightened = True
                    if delta.get("content"):
                        text_parts.append(delta["content"])
                    for tc in (delta.get("tool_calls") or []):
                        idx = tc.get("index", 0)
                        slot = tool_calls.setdefault(idx, {
                            "id": "", "type": "function",
                            "function": {"name": "", "arguments": ""},
                        })
                        if tc.get("id"):
                            slot["id"] = tc["id"]
                        fn = tc.get("function") or {}
                        if fn.get("name"):
                            slot["function"]["name"] = fn["name"]
                        if fn.get("arguments"):
                            slot["function"]["arguments"] += fn["arguments"]

            if not seen_done and finish_reason is None:
                raise _base.StreamConnectionLost("stream ended without [DONE] or a finish_reason")

            message = {"role": "assistant"}
            if tool_calls:
                message["content"] = "".join(text_parts) if text_parts else None
                message["tool_calls"] = [tool_calls[i] for i in sorted(tool_calls)]
            else:
                message["content"] = "".join(text_parts)
            return {
                "choices": [{"message": message, "finish_reason": finish_reason}],
                "usage": usage,
            }

        return _base._run_stream_attempt_with_retry(attempt)
