"""Traefik ForwardAuth for the vLLM endpoints: per-user keys without a gateway (#91).

Traefik sends each request's headers here before forwarding it. A caller is let
through when its bearer token is

  * a JupyterHub API token (from /hub/token, or JUPYTERHUB_API_TOKEN inside a
    user server), checked by asking the hub who owns it; or
  * the shared VLLM_API_KEY, accepted during the transition only.

On success the response carries `Authorization: Bearer <VLLM_API_KEY>`, which
Traefik copies onto the forwarded request (authResponseHeaders), so vLLM keeps its
single key. `X-Auth-User` names the caller for the access log.

Standard library only: it runs on a stock python image with no build step.
"""

import hashlib
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HUB_API = os.environ.get("HUB_API", "http://proxy-public.jupyter.svc.cluster.local/hub/api")
VLLM_API_KEY = os.environ["VLLM_API_KEY"]
ACCEPT_SHARED_KEY = os.environ.get("ACCEPT_SHARED_KEY", "true") == "true"
# Positive results are cached briefly so a burst of requests costs one hub call;
# a revoked hub token stops working within CACHE_TTL seconds.
CACHE_TTL = int(os.environ.get("CACHE_TTL", "60"))
NEGATIVE_TTL = int(os.environ.get("NEGATIVE_TTL", "10"))
# Paths vLLM itself serves without a key; keep them open so probes keep working.
OPEN_PATHS = ("/health", "/ping", "/metrics", "/version")

_cache = {}
_lock = threading.Lock()


def hub_user(token):
    """Return the hub username owning `token`, or None. Cached by token hash."""
    key = hashlib.sha256(token.encode()).hexdigest()
    now = time.monotonic()
    with _lock:
        hit = _cache.get(key)
        if hit and hit[1] > now:
            return hit[0]
    req = urllib.request.Request(HUB_API + "/user", headers={"Authorization": "token " + token})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            user = json.load(r).get("name")
    except urllib.error.HTTPError as e:
        if e.code not in (401, 403):
            raise
        user = None
    with _lock:
        if len(_cache) > 10000:
            _cache.clear()
        _cache[key] = (user, now + (CACHE_TTL if user else NEGATIVE_TTL))
    return user


def bearer(headers):
    value = headers.get("Authorization", "")
    scheme, _, token = value.partition(" ")
    if scheme.lower() in ("bearer", "token") and token.strip():
        return token.strip()
    return None


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, user=None, message=None):
        self._user = user
        self.send_response(code)
        if code == 200 and user is not None:
            self.send_header("Authorization", "Bearer " + VLLM_API_KEY)
            self.send_header("X-Auth-User", user)
        body = b""
        if message:
            body = json.dumps({"error": {"message": message, "type": "authentication_error",
                                         "code": code}}).encode()
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            return self._reply(200)
        uri = self.headers.get("X-Forwarded-Uri", "/")
        path = uri.split("?", 1)[0]
        # CORS preflights carry no credentials; vLLM answers them itself.
        if path in OPEN_PATHS or self.headers.get("X-Forwarded-Method") == "OPTIONS":
            return self._reply(200)
        token = bearer(self.headers)
        if token is None:
            return self._reply(401, message="Missing bearer token. Use a JupyterHub API token "
                                            "(https://jupyterhub.cirrus.carlboettiger.info/hub/token).")
        if ACCEPT_SHARED_KEY and token == VLLM_API_KEY:
            return self._reply(200, user="shared-key")
        try:
            user = hub_user(token)
        except Exception as e:  # hub unreachable: fail closed, say why
            self.log_message("hub lookup failed: %r", e)
            return self._reply(503, message="Token check unavailable; try again shortly.")
        if user is None:
            return self._reply(401, message="Invalid or revoked token.")
        return self._reply(200, user=user)

    # Traefik forwards the original method, so answer every one the same way.
    do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_GET

    def log_request(self, code="-", size="-"):
        # One line per decision; never the token. Skip health checks and open paths.
        user = getattr(self, "_user", None)
        if self.path == "/healthz" or (code == 200 and user is None):
            return
        self.log_message("%s %s %s %s", code, user or "-", self.headers.get("X-Forwarded-Host", "-"),
                         self.headers.get("X-Forwarded-Uri", "-"))


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
