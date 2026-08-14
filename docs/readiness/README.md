# Daily-driver readiness ledger

The [generated ledger](ledger.json) records what Ghostlight has actually proven and what still needs a test. It is an evidence inventory, not a release promise. Every proven claim names the source commit and SHA-256 of its receipt; evidence from an older commit stays visibly bound to that commit.

Current status: **Needs a test**. Three of seven claims have qualifying historical receipts:

| Claim | Status | Boundary |
| --- | --- | --- |
| Remote-profile continuity | Proven | Synthetic tabs, cookie, and local storage survived runtime recreation. |
| Decoded media | Proven | Four-phase direct-LAN runs recorded decoded frames, selected UDP, and dropped-frame counters. |
| Accepted input | Proven | X11 actions produced causal client-side pixel markers in four-phase runs. |
| Singular controller ownership | Needs a test | No qualifying live recovery matrix is committed. |
| Sleep/wake recovery | Needs a test | Relaunch evidence does not establish actual sleep/wake recovery. |
| Peripheral readiness | Needs a test | Unit and API tests do not establish an OS permission prompt plus real device use. |
| Real-account persistence | Needs a test | This requires an explicitly consented witness; synthetic evidence cannot satisfy it. |

Calendar duration is never a gate. Recovery evidence uses the bounded scenario and cleanup receipts in [Native recovery matrix](../operations/native-recovery.md).

## Privacy boundary

The ledger contains no URLs, hostnames, filenames, screenshots, DOM, page content, cookies, credentials, account identifiers, or media. It retains only claim IDs, source commits, evidence-recording timestamps, synthetic or explicit-consent classification, gate booleans, and receipt digests. The source evidence remains in its existing privacy-reviewed location; the generated ledger omits its path. When a claim has history, its newest recorded receipt decides the current label.

`evidence.json` is strict input. Unknown claims, unknown fields, forged digests, calendar fields, and synthetic real-account evidence fail generation. A claim with no evidence becomes `Needs a test`; any asserted false gate becomes `Failed`; only complete true gates become `Proven`.

Rebuild and verify the committed ledger:

```sh
node tools/test-build-readiness-ledger.mjs
node tools/build-readiness-ledger.mjs docs/readiness/evidence.json /tmp/ghostlight-readiness-ledger.json
cmp docs/readiness/ledger.json /tmp/ghostlight-readiness-ledger.json
```
