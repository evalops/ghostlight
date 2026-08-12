#!/usr/bin/env python3
"""Privacy-safe loopback pages used by the persistence acceptance test."""

import datetime
import html
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

MARKER = os.environ.get("GHOSTLIGHT_ACCEPTANCE_MARKER", "ghostlight-synthetic")
LOG_PATH = Path("/home/neko/.config/chromium/acceptance-requests.jsonl")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        cookie = self.headers.get("Cookie", "")
        record = {
            "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "path": parsed.path,
            "query": query,
            "cookie": cookie,
        }
        with LOG_PATH.open("a", encoding="utf-8") as output:
            output.write(json.dumps(record, sort_keys=True) + "\n")

        if parsed.path == "/storage-report":
            self.send_response(204)
            self.end_headers()
            return

        if parsed.path not in {"/state-a", "/state-b"}:
            self.send_error(404)
            return

        tab = "A" if parsed.path == "/state-a" else "B"

        body = f"""<!doctype html><html><head><meta charset=\"utf-8\">
<title>Ghostlight Synthetic Tab {tab}</title><style>
body {{background:#0c1220;color:#eef4ff;font:27px system-ui;margin:52px}}
.card {{border:3px solid #68d8ff;border-radius:22px;padding:36px;max-width:1150px}}
h1 {{color:#68d8ff}} code {{color:#a0ffbb}}</style></head><body><div class=\"card\">
<h1>Ghostlight synthetic persistence proof — tab {tab}</h1>
<p>Marker: <code>{html.escape(MARKER)}</code></p>
<p>Cookie: <code>{html.escape(cookie or "none")}</code></p>
<p id=\"storage\"></p>
<label>Latency marker <input autofocus id=\"latency\" aria-label=\"Latency marker\" style=\"font:inherit;width:22rem\"></label>
</div><script>
const key = 'ghostlight-acceptance-storage';
const priorStorage = localStorage.getItem(key) || 'none';
document.querySelector('#storage').textContent = 'Storage before load: ' + priorStorage;
localStorage.setItem(key, {json.dumps(MARKER)});
fetch('/storage-report?tab={tab}&value=' + encodeURIComponent(priorStorage), {{cache: 'no-store'}})
  .finally(() => window.__ghostlightStorageReported = true);
document.querySelector('#latency').focus();
</script></body></html>""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Set-Cookie", f"ghostlight_acceptance={MARKER}; Path=/; SameSite=Lax; Max-Age=604800")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer(("127.0.0.1", 18083), Handler).serve_forever()
