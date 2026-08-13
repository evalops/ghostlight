# Chrome to Ghostlight continuity

Ghostlight continuity transfers chosen HTTP or HTTPS tabs into a durable inbox and can keep a read-only mirror of enabled bookmarks or Reading List entries. Chrome remains authoritative. The remote browser opens an item after the user selects it in the macOS app.

## Privacy boundary

Chrome exposes the selected tab through [`activeTab`](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab). Sending a window requests `tabs` at action time. Bookmark and Reading List mirrors each request their own optional permission when enabled. Ghostlight uses local extension storage for its device credential and sync revision.

Passwords, cookies, autofill data, Google account credentials, browsing history, page contents, incognito tabs, `chrome://` pages, `file://` pages, URL fragments, embedded URL credentials, and credential-bearing query parameters stay in Chrome. Signing the remote Chromium profile into Chrome Sync remains a separate operator choice with a broader account-data boundary.

## Flow

1. In Ghostlight Home, select **Connect your Chrome**, name the device, and generate a pairing code.
2. Load `companion/chrome` as an unpacked extension in local Chrome and open its options.
3. Enter the Ghostlight control URL, the same device name, and the pairing code. Chrome asks for network access to that one control origin.
4. Open the toolbar action and send the current tab. **Send this window** requests tab access and creates one ordered, atomic batch of up to 25 tabs.
5. In extension settings, enable bookmarks or Reading List separately. The first full snapshot runs after Chrome grants that source's permission; event-driven updates and a 15-minute repair sync replace it at a higher revision.
6. In Ghostlight Home, select a handoff, bookmark, or unread Reading List item. Opening uses the normal controller lease, revision fence, and idempotent browser-command path.

The pairing code is a 256-bit random capability, expires after 10 minutes, and can be redeemed once. Control stores hashes of pairing and device bearer tokens. A paired device receives only `handoff:write library:replace`; it cannot read workspaces, tabs, streams, attachments, other handoffs, or control the browser. Revoking the device rejects its next write and deletes its mirrored library snapshot.

The extension stores its scoped device token in `chrome.storage.local`, restricted to trusted extension contexts. The token never enters `storage.sync`, a URL, a log message, or page-accessible storage.

## Delivery and conflicts

Each handoff includes a device-generated idempotency key. Repeating the same request returns the original inbox item; reusing the key with another body fails. Window batches commit all tabs or none and preserve group order. A workspace accepts at most 100 pending handoffs. Pending items have two terminal states: `opened` and `dismissed`.

Opening uses the deterministic browser-command key `chrome-handoff-{handoff-id}`. If the app loses its response after Chromium applies the command, retrying returns the original command receipt instead of opening another tab. The inbox item becomes `opened` only after control reports that command as applied.

Library snapshots carry a monotonic per-device revision and body hash. A lower revision is stale; different content at the same revision is a conflict; the same revision and body is an idempotent retry. A higher snapshot replaces that device's prior source atomically. There is no Ghostlight-to-Chrome write path, so folder moves and renames resolve from Chrome's next authoritative snapshot.

## Scope boundaries

| Scope | Chrome API | Conflict identity | Default |
| --- | --- | --- | --- |
| Selected tab | `activeTab` | Handoff ID | Shipped, explicit action |
| Selected window | `tabs` requested at runtime | Group ID plus ordered handoff IDs | Shipped, explicit action |
| Reading list | `readingList`, Chrome 120+ | Device ID plus canonical URL | Shipped, opt-in mirror |
| Bookmarks | `bookmarks` requested at runtime | Device ID plus Chrome bookmark ID | Shipped, opt-in mirror |
| Recently closed sessions | `sessions` | Device session ID | Off |
| Full history | `history` | URL plus visit timestamp | Excluded by default |
| Cookies, passwords, autofill | No safe Ghostlight transfer contract | None | Excluded |

Optional scopes use [`optional_permissions`](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions). Unsupported and credential-bearing URLs remain in Chrome. Disabling a source clears its server mirror before releasing the Chrome permission. Removing permission through Chrome queues the same clear for the repair loop. Revoking the paired device also removes its server-side mirror.
