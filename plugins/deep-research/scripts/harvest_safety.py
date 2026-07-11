"""Safety layer: SSRF guard, domain blacklist, path sandbox, rate limiter,
URL normalization. Zero dependency on the rest of harvest -- importable
side-effect free (install_ssrf_guard() is explicit, not import-time)."""
import ipaddress
import socket
import threading
import time
import urllib.parse

__all__ = [
    "RateLimiter", "SSRFBlocked", "install_ssrf_guard", "tool_request_guard",
    "_ssrf_validate_and_resolve", "_ssrf_precheck", "is_blacklisted",
    "_is_relative_to", "normalize_url", "_guarded_getaddrinfo",
]


class RateLimiter:
    """One lock-protected timestamp per backend instance. Critical section is
    timestamp-only; sleep and the actual call happen outside the lock."""

    def __init__(self, min_interval_s):
        self._min_interval = min_interval_s
        self._lock = threading.Lock()
        self._next_allowed = 0.0

    def acquire(self):
        with self._lock:
            now = time.monotonic()
            wait = max(0.0, self._next_allowed - now)
            self._next_allowed = max(now, self._next_allowed) + self._min_interval
        if wait > 0:
            time.sleep(wait)


class SSRFBlocked(Exception):
    pass


_tool_ctx = threading.local()
_real_getaddrinfo = socket.getaddrinfo


def _is_blocked_ip(ip_str):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return True
    return (ip.is_private or ip.is_loopback or ip.is_link_local
            or ip.is_reserved or ip.is_multicast or ip.is_unspecified)


def _guarded_getaddrinfo(host, *args, **kwargs):
    result = _real_getaddrinfo(host, *args, **kwargs)
    if getattr(_tool_ctx, "active", False):
        for item in result:
            ip = item[4][0]
            if _is_blocked_ip(ip):
                raise SSRFBlocked(f"blocked address for host {host}: {ip}")
    return result


def install_ssrf_guard():
    """Monkeypatch socket.getaddrinfo. Called at run-start, not at import
    time, so importing this module (e.g. from the SubagentStop hook) stays
    side-effect free."""
    socket.getaddrinfo = _guarded_getaddrinfo


class tool_request_guard:
    """Context manager marking the current thread as executing a tool call
    whose network target may be attacker/model controlled. Only active
    inside this context does the guard reject private/loopback/reserved
    addresses -- gateway chat-completion calls are made outside it."""

    def __enter__(self):
        self._prev = getattr(_tool_ctx, "active", False)
        _tool_ctx.active = True
        return self

    def __exit__(self, exc_type, exc, tb):
        _tool_ctx.active = self._prev
        return False


def _ssrf_validate_and_resolve(url):
    """Shared SSRF validation: scheme + host-presence checks, then a single
    guarded socket.getaddrinfo() call (raises SSRFBlocked if any returned
    address is private/loopback/reserved). Returns (host, port, first_ip)
    so callers that need the actual resolved address -- not just a pass/
    fail check -- don't have to resolve a second time."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise SSRFBlocked(f"unsupported scheme: {parts.scheme}")
    host = parts.hostname
    if not host:
        raise SSRFBlocked("no host in URL")
    port = parts.port or (443 if parts.scheme == "https" else 80)
    results = socket.getaddrinfo(host, port)
    return host, port, results[0][4][0]


def _ssrf_precheck(url):
    _ssrf_validate_and_resolve(url)


def is_blacklisted(url, blacklist_domains):
    try:
        host = urllib.parse.urlsplit(url).hostname
    except ValueError:
        return True
    if not host:
        return False
    # .hostname (not manual "@"/":" splitting) correctly strips userinfo,
    # port, and IPv6 brackets -- manual colon-splitting breaks on IPv6
    # literals, which contain colons inside the address itself.
    host = host.lower().rstrip(".")
    for domain in blacklist_domains:
        domain = domain.lower().rstrip(".")
        if host == domain or host.endswith("." + domain):
            return True
    return False


def _is_relative_to(path, base):
    try:
        path.relative_to(base)
        return True
    except ValueError:
        return False


def normalize_url(url):
    url = (url or "").strip()
    if url.startswith("local://"):
        return "local://" + url[len("local://"):].strip("/")
    try:
        parts = urllib.parse.urlsplit(url)
        netloc = parts.netloc.lower()
        path = parts.path.rstrip("/")
        return urllib.parse.urlunsplit((parts.scheme.lower(), netloc, path, parts.query, ""))
    except ValueError:
        # Malformed URL (e.g. a broken IPv6 literal) from model output or a
        # search backend result -- treat as non-normalizable rather than
        # crashing the worker. Returning it unnormalized just means it
        # won't match any journal-derived key, which correctly fails
        # citation validation instead of taking down the whole run.
        return url
