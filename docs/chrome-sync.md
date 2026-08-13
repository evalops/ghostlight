# Chrome to Ghostlight continuity

Ghostlight does not copy a Chrome profile or impersonate Chrome Sync. The shipped first slice transfers one user-selected HTTP or HTTPS tab into a durable Ghostlight inbox. The remote browser opens it only after the user selects **Open** in the macOS app.

## Why the boundary is narrow

Chrome exposes the selected tab to an extension through [`activeTab`](https://developer.chrome.com/docs/extensions/develop/concepts/activeTab) after a toolbar click, without persistent access to every page. Reading all tabs or history requires broader permissions and produces browsing-history warnings. Extension [`storage.sync`](https://developer.chrome.com/docs/extensions/reference/api/storage) synchronizes extension-owned settings; it is not an API for Chrome's bookmarks, passwords, cookies, or complete profile.

Ghostlight therefore excludes passwords, cookies, autofill data, Google account credentials, browsing history, page contents, incognito tabs, `chrome://` pages, `file://` pages, URL fragments, embedded URL credentials, and credential-bearing query parameters. Signing the remote Chromium profile into Chrome Sync remains a separate operator choice because it gives that persistent Linux profile access to the selected account data and any custom sync passphrase.

## Shipped flow

1. In Ghostlight Home, select **Connect your Chrome**, name the device, and generate a pairing code.
2. Load `companion/chrome` as an unpacked extension in local Chrome and open its options.
3. Enter the Ghostlight control URL, the same device name, and the pairing code. Chrome asks for network access to that one control origin.
4. On a normal web page, select the extension toolbar action. The extension sends that tab's title and URL to the workspace inbox.
5. In Ghostlight Home, select **Open** or **Dismiss**. Opening uses the normal controller lease, revision fence, and idempotent browser-command path.

The pairing code is a 256-bit random capability, expires after 10 minutes, and can be redeemed once. Control stores hashes of pairing and device bearer tokens. A paired device receives only `handoff:write`; it cannot read workspaces, tabs, streams, attachments, other handoffs, or control the browser. Revoking the device through `DELETE /v1/workspaces/{workspace}/chrome-devices/{device}` rejects its next write.

The extension stores its scoped device token in `chrome.storage.local`, restricted to trusted extension contexts. It does not put the token in `storage.sync`, a URL, a log message, or page-accessible storage.

## Delivery and conflicts

Each handoff includes a device-generated idempotency key. Repeating the same request returns the original inbox item; reusing the key with another body fails. A workspace accepts at most 100 pending handoffs. Pending items have two terminal states: `opened` and `dismissed`.

Opening uses the deterministic browser-command key `chrome-handoff-{handoff-id}`. If the app loses its response after Chromium applies the command, retrying returns the original command receipt instead of opening another tab. The inbox item becomes `opened` only after control reports that command as applied.

## Next scopes

Broader continuity should remain a set of independently consented scopes rather than one profile-sync switch.

| Scope | Chrome API | Conflict identity | Default |
| --- | --- | --- | --- |
| Selected tab | `activeTab` | Handoff ID | Shipped, explicit action |
| Selected window | `tabs` requested at runtime | Device ID plus tab snapshot ID | Off |
| Reading list | `readingList`, Chrome 120+ | Canonical URL | Off |
| Bookmarks | `bookmarks` requested at runtime | Ghostlight item ID plus Chrome bookmark ID | Off |
| Recently closed sessions | `sessions` | Device session ID | Off |
| Full history | `history` | URL plus visit timestamp | Not planned by default |
| Cookies, passwords, autofill | No safe Ghostlight transfer contract | None | Excluded |

Reading-list and bookmark synchronization need an operation log with source device, monotonic revision, tombstone, and last acknowledged revision. Folder moves and concurrent renames must remain visible conflicts; last-write-wins would silently destroy user organization. The server should retain only the fields required for the enabled scope and expose per-device export and deletion before either scope ships.

Chrome recommends requesting optional permissions at runtime so users can enable only the feature that needs them. Future bookmark, reading-list, session, or selected-window work must use [`optional_permissions`](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions), preserve incognito exclusion, and add a permission-specific explanation before Chrome's prompt.
