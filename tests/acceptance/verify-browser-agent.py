#!/usr/bin/env python3

import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def fail(message):
    raise RuntimeError(message)


def request_json(base_url, api_token, method, path, body=None, headers=None, allowed_http_errors=()):
    payload = None if body is None else json.dumps(body).encode("utf-8")
    request_headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json",
        **(headers or {}),
    }
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}{path}",
        data=payload,
        headers=request_headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            data = response.read()
            return response.status, json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        if error.code in allowed_http_errors:
            try:
                return error.code, json.loads(detail)
            except json.JSONDecodeError:
                return error.code, detail
        fail(f"{method} {path} returned HTTP {error.code}: {detail}")


def queue_navigation(control_url, api_token, lease_token, phase, suffix, url, current, get_session):
    headers = {
        "Idempotency-Key": f"acceptance-native-bridge-{phase}-{suffix}",
        "X-Ghostlight-Lease-Token": lease_token,
    }
    for _attempt in range(3):
        status, queued = request_json(
            control_url,
            api_token,
            "POST",
            "/v1/sessions/default/commands",
            {
                "type": "navigate",
                "tab_id": current["active_tab_id"],
                "url": url,
                "expected_revision": current["revision"],
            },
            headers,
            allowed_http_errors=(409,),
        )
        if status != 409:
            return queued, current
        if not isinstance(queued, dict) or queued.get("error", {}).get("code") != "stale_revision":
            fail(f"navigation command returned unexpected conflict: {queued!r}")
        current = get_session()
    fail("navigation command revision remained stale after 3 attempts")


def wait_for(description, load, accept, timeout_seconds=90):
    deadline = time.monotonic() + timeout_seconds
    last = None
    while time.monotonic() < deadline:
        last = load()
        if accept(last):
            return last
        time.sleep(0.5)
    fail(f"timed out waiting for {description}; last response: {last!r}")


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def main():
    if len(sys.argv) != 6:
        fail("usage: verify-browser-agent.py <control-url> <api-token> <target-url> <phase> <receipt>")
    control_url, api_token, target_url, phase, receipt_path = sys.argv[1:]
    phase_started = datetime.now(timezone.utc)

    def get_session():
        _, session = request_json(control_url, api_token, "GET", "/v1/sessions/default")
        return session

    session = wait_for(
        "browser-agent heartbeat",
        get_session,
        lambda value: value.get("runtime_state") == "ready"
        and value.get("last_heartbeat")
        and parse_time(value["last_heartbeat"]) > phase_started
        and value.get("active_tab_id"),
    )
    active_tab = next(
        (tab for tab in session.get("tabs", []) if tab.get("id") == session["active_tab_id"]),
        None,
    )
    original_url = active_tab.get("url", "") if active_tab else ""
    if not original_url.startswith(("http://", "https://")):
        fail(f"active tab cannot be restored after navigation proof: {original_url!r}")
    _, lease = request_json(
        control_url,
        api_token,
        "POST",
        "/v1/sessions/default/leases",
        {"client_id": f"acceptance-{phase}"},
    )
    lease_token = lease["token"]
    try:
        def submit_navigation(url, current, suffix):
            queued, current = queue_navigation(
                control_url,
                api_token,
                lease_token,
                phase,
                suffix,
                url,
                current,
                get_session,
            )

            def get_command():
                _, value = request_json(
                    control_url,
                    api_token,
                    "GET",
                    f"/v1/sessions/default/commands/{queued['id']}",
                )
                if value.get("state") == "failed":
                    fail(f"browser-agent command failed: {value!r}")
                return value

            completed_command = wait_for(
                "browser-agent command acknowledgment",
                get_command,
                lambda value: value.get("state") == "applied"
                and value.get("acknowledged_at")
                and value.get("completed_at"),
            )
            heartbeat = wait_for(
                "browser-agent navigation heartbeat",
                get_session,
                lambda value: value.get("revision", 0) > current["revision"]
                and parse_time(value["last_heartbeat"]) > parse_time(current["last_heartbeat"])
                and any(
                    tab.get("id") == value.get("active_tab_id")
                    and tab.get("url") == url
                    and not tab.get("loading")
                    for tab in value.get("tabs", [])
                ),
            )
            return queued["id"], completed_command, heartbeat

        command_id, completed, navigated = submit_navigation(target_url, session, "prove")
        restore_command_id, _, restored = submit_navigation(original_url, navigated, "restore")
    finally:
        request_json(
            control_url,
            api_token,
            "DELETE",
            f"/v1/sessions/default/leases/{lease['id']}",
            headers={"X-Ghostlight-Lease-Token": lease_token},
        )

    receipt = {
        "phase": phase,
        "session_id": navigated["id"],
        "runtime_state": navigated["runtime_state"],
        "active_tab_id": navigated["active_tab_id"],
        "last_heartbeat": navigated["last_heartbeat"],
        "command_id": command_id,
        "command_state": completed["state"],
        "acknowledged_at": completed["acknowledged_at"],
        "completed_at": completed["completed_at"],
        "target_url": target_url,
        "restored_url": original_url,
        "restore_command_id": restore_command_id,
        "restored_revision": restored["revision"],
    }
    Path(receipt_path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    main()
