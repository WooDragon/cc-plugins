"""harvest_clients.factory - config -> client-factory dispatcher."""

import os

from harvest_clients.gateway import GatewayClient
from harvest_clients.anthropic import AnthropicGatewayClient
from harvest_clients.responses import ResponsesGatewayClient
from harvest_clients.gemini import GeminiNativeGatewayClient
from harvest_clients.grok_cli import GrokCliClient


def make_client_factory(config):
    gw = config["gateway"]
    api_key = os.environ.get(gw["api_key_env"], "")
    # Chat-completion calls (panel + judge) run their own agentic reasoning
    # and can legitimately take far longer than a single search/fetch call
    # -- decoupled from limits.call_timeout_s (which bounds only the fetch/
    # search backends) so raising one doesn't silently also relax the
    # other. .get() with a default so an older config without this key
    # doesn't KeyError; it just falls back to the same default declared in
    # harvest.config.json.
    timeout = config.get("limits", {}).get("completion_timeout_s", 600)
    # Anthropic requires max_tokens; OpenAI treats it as optional so the
    # OpenAI path never set it. Read from config with a generous default so
    # large findings/judge outputs aren't truncated (truncation would surface
    # as finish_reason=max_tokens and a half-parsed JSON). Same .get()-with-
    # default back-compat pattern as completion_timeout_s. Also doubles as
    # the Responses path's max_output_tokens (same "how big can a completion
    # be" knob, one config value, see ResponsesGatewayClient).
    max_tokens = config.get("limits", {}).get("completion_max_tokens", 16384)
    # ADR-011: deliberate global default lowering, not a like-for-like
    # migration. Before this key existed, AnthropicGatewayClient never sent
    # output_config at all, so the provider's own default ("high") applied.
    # Every existing config -- including ones written before this key was
    # added -- now gets "medium" via this .get() default, because thinking-
    # heavy "high" effort was identified as the main per-step latency driver
    # for claude in the panel (see ADR-011's wall-clock investigation). This
    # is NOT the usual back-compat contract ("old config behaves exactly as
    # before"); it is an intentional behavior change that happens to reuse
    # the same .get()-with-default mechanism. Config authors who want the
    # old "high" back can set limits.claude_effort explicitly.
    effort = config.get("limits", {}).get("claude_effort", "medium")
    # Escape hatch for the /responses instance-affinity cache behavior: this
    # is observed, gateway-specific behavior (see ResponsesGatewayClient's
    # docstring), not a guaranteed OpenAI feature. If a future gateway/
    # provider swap makes /responses worse than plain /chat/completions,
    # config can flip this back to "chat_completions" without a code change
    # -- gpt* then falls through to the same plain GatewayClient path gemini
    # used before GeminiNativeGatewayClient existed, rather than needing a
    # second personality inside ResponsesGatewayClient itself.
    gpt_endpoint = config.get("limits", {}).get("gpt_endpoint", "responses")
    # Same escape hatch pattern as gpt_endpoint, for the Gemini-native
    # generateContent path (see GeminiNativeGatewayClient's docstring): if
    # the gateway's implicit prefix caching turns out not to apply to this
    # protocol either, config can flip back to "chat_completions" without a
    # code change -- gemini* then falls through to the same plain
    # GatewayClient path it used before this client existed.
    gemini_endpoint = config.get("limits", {}).get("gemini_endpoint", "native")
    # ADR-013: streaming fail-fast watchdog config. ttft (time-to-first-token)
    # bounds the initial connection + wait-for-first-frame; once any content
    # delta arrives each client's own settimeout() call tightens to the
    # (much shorter) inter-token bound, so a stalled-mid-stream gateway is
    # caught fast instead of hanging for the full ttft window every token.
    # Same .get()-with-default back-compat pattern as every other key here --
    # an older config without these keys gets the same defaults declared in
    # harvest.config.json (streaming on, generous but bounded timeouts).
    stream_ttft = config.get("limits", {}).get("stream_ttft_timeout_s", 300)
    stream_inter = config.get("limits", {}).get("stream_inter_token_timeout_s", 90)
    anthropic_stream = config.get("limits", {}).get("anthropic_stream", True)
    gpt_stream = config.get("limits", {}).get("gpt_stream", True)
    gemini_stream = config.get("limits", {}).get("gemini_stream", True)
    gateway_stream = config.get("limits", {}).get("gateway_stream", True)
    gateway_stream_options = config.get("limits", {}).get("gateway_stream_options", False)
    # grok-* models bypass the gateway entirely (GrokCliClient shells out to
    # the local grok CLI) -- effort/max_urls are grok-specific knobs with no
    # HTTP-gateway equivalent, hence their own config keys rather than reuse
    # of claude_effort/gpt_endpoint-style names. Same .get()-with-default
    # back-compat pattern as every other key here.
    grok_effort = config.get("limits", {}).get("grok_effort", "medium")
    grok_max_urls = config.get("limits", {}).get("grok_max_urls", 12)
    # grok CLI calls (agentic web+X search inside a single invocation) run
    # far longer than a typical gateway HTTP completion -- independent
    # timeout key rather than reusing completion_timeout_s, so raising one
    # doesn't silently also relax the other for every gateway-backed client.
    grok_timeout = config.get("limits", {}).get("grok_timeout_s", 240)

    def factory(model_id):
        # claude models go through the Anthropic-native /messages path so
        # prompt caching can take effect; gpt models go through the
        # Responses path for the same reason (see ResponsesGatewayClient);
        # gemini models go through the Gemini-native generateContent path for
        # the same reason (see GeminiNativeGatewayClient); everything else
        # (and gpt/gemini when their *_endpoint switch is flipped off) stays
        # on the OpenAI-compatible /chat/completions gateway. All four share
        # the same complete(messages, tools) interface, so
        # run_judge_with_fallback can freely mix client types across its
        # candidates.
        if model_id.startswith("claude"):
            return AnthropicGatewayClient(gw["base_url"], api_key, model_id, timeout, max_tokens, effort=effort,
                                           stream_enabled=anthropic_stream, ttft_timeout=stream_ttft,
                                           inter_token_timeout=stream_inter)
        if model_id.startswith("gpt") and gpt_endpoint == "responses":
            return ResponsesGatewayClient(gw["base_url"], api_key, model_id, timeout, max_tokens,
                                           stream_enabled=gpt_stream, ttft_timeout=stream_ttft,
                                           inter_token_timeout=stream_inter,
                                           stream_options=gateway_stream_options)
        if model_id.startswith("gemini") and gemini_endpoint == "native":
            return GeminiNativeGatewayClient(gw["base_url"], api_key, model_id, timeout, max_tokens,
                                              stream_enabled=gemini_stream, ttft_timeout=stream_ttft,
                                              inter_token_timeout=stream_inter)
        if model_id.startswith("grok"):
            return GrokCliClient(model_id, effort=grok_effort, timeout=grok_timeout, max_urls=grok_max_urls)
        return GatewayClient(gw["base_url"], api_key, model_id, timeout,
                              stream_enabled=gateway_stream, ttft_timeout=stream_ttft,
                              inter_token_timeout=stream_inter, stream_options=gateway_stream_options)

    return factory
