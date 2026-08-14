#!/usr/bin/env python3

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("verify-browser-agent.py")
SPEC = importlib.util.spec_from_file_location("verify_browser_agent", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class QueueNavigationTests(unittest.TestCase):
    def setUp(self):
        self.original_request_json = MODULE.request_json

    def tearDown(self):
        MODULE.request_json = self.original_request_json

    def test_retries_only_stale_revision_with_fresh_session(self):
        requests = []
        responses = [
            (409, {"error": {"code": "stale_revision"}}),
            (201, {"id": "command-1"}),
        ]

        def request_json(*args, **kwargs):
            requests.append((args, kwargs))
            return responses.pop(0)

        MODULE.request_json = request_json
        queued, current = MODULE.queue_navigation(
            "http://control",
            "token",
            "lease",
            "before",
            "prove",
            "https://example.test",
            {"active_tab_id": "tab-1", "revision": 4},
            lambda: {"active_tab_id": "tab-1", "revision": 5},
        )

        self.assertEqual(queued, {"id": "command-1"})
        self.assertEqual(current["revision"], 5)
        self.assertEqual(requests[0][0][4]["expected_revision"], 4)
        self.assertEqual(requests[1][0][4]["expected_revision"], 5)
        self.assertEqual(requests[0][1]["allowed_http_errors"], (409,))

    def test_rejects_non_stale_conflict(self):
        MODULE.request_json = lambda *args, **kwargs: (409, {"error": {"code": "lease_conflict"}})
        with self.assertRaisesRegex(RuntimeError, "unexpected conflict"):
            MODULE.queue_navigation(
                "http://control",
                "token",
                "lease",
                "before",
                "prove",
                "https://example.test",
                {"active_tab_id": "tab-1", "revision": 4},
                lambda: {"active_tab_id": "tab-1", "revision": 5},
            )


if __name__ == "__main__":
    unittest.main()
