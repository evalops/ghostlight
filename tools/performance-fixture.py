#!/usr/bin/env python3
"""Self-contained, privacy-safe pages used by the streaming benchmark."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


BASE_STYLE = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; background: #101827; color: #e7eefb; }
body { font: 22px/1.45 system-ui, -apple-system, sans-serif; }
#causal-marker {
  position: fixed; z-index: 1000; top: 24px; left: 24px;
  width: 440px; height: 116px; padding: 22px 28px;
  border: 4px solid #c3ffdc; border-radius: 14px;
  background: #10251b; color: #b7ffd1; font: 700 36px/1.8 ui-monospace, monospace;
  letter-spacing: .04em; text-align: center;
}
#causal-marker.active { background: #00ff66; color: #001a08; }
.shell { max-width: 1720px; margin: 0 auto; padding: 190px 72px 80px; }
.topbar { display: flex; align-items: center; gap: 24px; padding: 18px 24px; background: #1a2942; border: 1px solid #2d4669; border-radius: 12px; }
.logo { font-size: 32px; font-weight: 750; color: #8ed1ff; }
.search { flex: 1; padding: 15px 20px; border-radius: 10px; border: 1px solid #53709c; background: #102039; color: #eef5ff; font: inherit; }
.columns { display: grid; grid-template-columns: 250px 1fr 340px; gap: 28px; margin-top: 28px; }
.panel { padding: 22px; border: 1px solid #2d4669; border-radius: 12px; background: #15233a; }
.panel h2 { margin: 0 0 16px; color: #8ed1ff; font-size: 24px; }
.nav div, .message { padding: 12px 14px; border-radius: 8px; }
.nav div:nth-child(2), .message:nth-child(odd) { background: #1d3555; }
.message { border-bottom: 1px solid #2a405e; }
.message strong { color: #f4f8ff; }
.muted { color: #a8b8cf; }
.input-card { margin-top: 28px; }
#typing-input { width: min(760px, 100%); padding: 18px; border: 2px solid #5a7ca8; border-radius: 10px; background: #0e1a2d; color: #f1f6ff; font: inherit; }
.scroll-block { min-height: 2550px; }
.scroll-block .message { margin: 22px 0; padding: 30px; min-height: 220px; }
#animation-stage { position: relative; height: 1600px; overflow: hidden; border-radius: 14px; background: #08131f; }
.orb { position: absolute; width: 220px; height: 220px; border-radius: 50%; filter: blur(1px); animation: drift 5s ease-in-out infinite alternate; }
.orb.one { background: #31b7ff; left: 8%; top: 20%; }
.orb.two { background: #ff6b9c; left: 54%; top: 36%; animation-delay: -1.7s; animation-duration: 7s; }
.orb.three { background: #c9ff5e; left: 32%; top: 70%; animation-delay: -3.1s; animation-duration: 6s; }
@keyframes drift { from { transform: translate3d(-80px, -70px, 0) scale(.75); } to { transform: translate3d(620px, 390px, 0) scale(1.65); } }
"""


def page_body(kind: str) -> str:
    if kind == "scrolling":
        content = '<div class="scroll-block">' + "".join(
            f'<article class="message"><strong>Thread {index:02d}: release planning</strong>'
            f'<p class="muted">The synthetic inbox row contains fixed text for scroll rendering and screenshot review.</p>'
            f'<p>Message body {index:02d}: verify the deployment window, owner, and rollback command before the next review.</p></article>'
            for index in range(1, 14)
        ) + "</div>"
    elif kind == "typing":
        content = """
        <section class="panel input-card">
          <h2>Compose message</h2>
          <p class="muted">The input receives synthetic text-entry events from the X11 benchmark driver.</p>
          <input id="typing-input" aria-label="Message body" autocomplete="off" spellcheck="false">
          <p id="typing-count" class="muted">Characters: 0</p>
        </section>
        """
    elif kind == "animation":
        content = """
        <section id="animation-stage" aria-label="Synthetic animation">
          <div class="orb one"></div><div class="orb two"></div><div class="orb three"></div>
        </section>
        """
    else:
        content = """
        <div class="columns">
          <aside class="panel nav"><h2>Inbox</h2><div>Primary</div><div>Updates</div><div>Drafts</div><div>Archive</div></aside>
          <main class="panel"><h2>Primary</h2>
            <article class="message"><strong>Build review</strong><span class="muted"> 09:42</span><p>Review the current viewer image and the streaming receipt before changing the runtime defaults.</p></article>
            <article class="message"><strong>Acceptance evidence</strong><span class="muted"> 09:18</span><p>Confirm the browser session, screenshot audit, and persistence receipt are linked to the exact source.</p></article>
            <article class="message"><strong>Performance run</strong><span class="muted"> 08:55</span><p>Compare the paired control and candidate values for decoded frames, freezes, input markers, and CPU.</p></article>
          </main>
          <aside class="panel"><h2>Calendar</h2><p class="muted">09:00 &nbsp; Viewer review</p><p class="muted">11:30 &nbsp; Release check</p><p class="muted">15:00 &nbsp; Acceptance run</p></aside>
        </div>
        """

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ghostlight synthetic {kind}</title><style>{BASE_STYLE}</style></head>
<body data-workload="{kind}">
<div id="causal-marker" aria-live="polite">WAITING</div>
<div class="shell"><header class="topbar"><div class="logo">Mail</div><input class="search" aria-label="Search mail" value="Synthetic Gmail-like fixture"></header>{content}</div>
<script>
(() => {{
  const marker = document.querySelector('#causal-marker');
  const typingInput = document.querySelector('#typing-input');
  let sequence = 0;
  let markerResetTimer = 0;
  window.__ghostlightResetMarker = () => {{
    window.clearTimeout(markerResetTimer);
    marker.classList.remove('active');
    marker.textContent = 'WAITING';
  }};
  window.__ghostlightMarkerState = () => ({{ sequence, active: marker.classList.contains('active') }});
  const mark = (source) => {{
    sequence += 1;
    marker.dataset.sequence = String(sequence);
    marker.dataset.source = source;
    marker.textContent = `INPUT ${{String(sequence).padStart(6, '0')}}`;
    marker.classList.add('active');
    window.clearTimeout(markerResetTimer);
    markerResetTimer = window.setTimeout(window.__ghostlightResetMarker, 750);
  }};
  window.addEventListener('keydown', (event) => {{ if (event.key === 'F8') mark('keydown'); }});
  window.addEventListener('input', (event) => {{ if (event.target === typingInput) {{ document.querySelector('#typing-count').textContent = `Characters: ${{typingInput.value.length}}`; }} }});
  if (typingInput) typingInput.addEventListener('focus', () => typingInput.setSelectionRange(typingInput.value.length, typingInput.value.length));
}})();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        route = self.path.split("?", 1)[0].strip("/") or "static-gmail"
        if route not in {"static-gmail", "scrolling", "typing", "animation"}:
            self.send_error(404)
            return
        body = page_body(route).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


ThreadingHTTPServer(("127.0.0.1", 18083), Handler).serve_forever()
