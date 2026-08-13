import Foundation
import XCTest
@testable import GhostlightApp

final class NativeSessionTests: XCTestCase {
    override func tearDown() {
        NativeSessionURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testBrowserSessionDecodesNativeContract() throws {
        let session = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8))

        XCTAssertEqual(session.id, "session-1")
        XCTAssertEqual(session.revision, 7)
        XCTAssertEqual(session.tabs.first?.title, "Example")
        XCTAssertEqual(session.activeTabID, "tab-1")
        XCTAssertNil(session.controller)
        XCTAssertNil(session.stream)
    }

    func testBrowserSessionDecodesQueuedAndTerminalCommandReceipts() throws {
        let payload = Self.sessionJSON.replacingOccurrences(
            of: "\"active_tab_id\":\"tab-1\"",
            with: #"""
            "active_tab_id":"tab-1","command_receipts":[
              {"id":"command-queued","sequence":1,"session_id":"session-1","type":"reload","tab_id":"tab-1","expected_revision":7,"lease_epoch":2,"state":"queued","created_at":"2026-08-13T12:00:02Z"},
              {"id":"command-failed","sequence":2,"session_id":"session-1","type":"back","tab_id":"tab-1","expected_revision":7,"lease_epoch":2,"state":"failed","error_code":"navigation_failed","error":"History entry unavailable","result":{"retryable":false},"resulting_revision":8,"completed_at":"2026-08-13T12:00:03Z","created_at":"2026-08-13T12:00:02Z"}
            ]
            """#
        )

        let session = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(payload.utf8))

        XCTAssertEqual(session.commandReceipts.map(\.id), ["command-queued", "command-failed"])
        XCTAssertEqual(session.commandReceipts[0].state, .queued)
        XCTAssertEqual(session.commandReceipts[1].state, .failed)
        XCTAssertEqual(session.commandReceipts[1].errorCode, "navigation_failed")
        XCTAssertEqual(session.commandReceipts[1].resultingRevision, 8)
        XCTAssertNotNil(session.commandReceipts[1].completedAt)
        XCTAssertEqual(session.commandReceipts[1].result, .object(["retryable": .bool(false)]))
    }

    func testSessionControllerSummaryDecodesWithoutLeaseSecret() throws {
        let payload = Self.sessionJSON.replacingOccurrences(
            of: "\"controller\":null",
            with: "\"controller\":{\"id\":\"lease-1\",\"session_id\":\"session-1\",\"client_id\":\"other-mac\",\"epoch\":3,\"expires_at\":\"2030-08-13T12:00:30Z\",\"renew_after\":\"2030-08-13T12:00:10Z\"}"
        )
        let session = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(payload.utf8))

        XCTAssertEqual(session.controller?.clientID, "other-mac")
        XCTAssertNil(session.controller?.token)
    }

    func testAttachmentDecodesControlContractFilename() throws {
        let payload = #"{"id":"attachment-1","session_id":"session-1","filename":"brief.pdf","content_type":"application/pdf","size":42,"digest":"sha256:abc","created_at":"2026-08-13T12:00:00Z"}"#
        let attachment = try SessionJSON.decoder.decode(Attachment.self, from: Data(payload.utf8))

        XCTAssertEqual(attachment.filename, "brief.pdf")
        XCTAssertEqual(attachment.size, 42)
    }

    func testCreateSessionUsesContractBodyAndStableIdempotencyKey() async throws {
        var captured: URLRequest?
        NativeSessionURLProtocol.requestHandler = { request in
            captured = request
            return (Self.response(for: request, status: 201), Data(Self.sessionJSON.utf8))
        }

        let client = SessionClient(session: makeSession())
        _ = try await client.createSession(
            at: try XCTUnwrap(URL(string: "https://control.example.test/base")),
            apiToken: "api-secret",
            idempotencyKey: "mac-client-1"
        )

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.absoluteString, "https://control.example.test/base/v1/sessions")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Idempotency-Key"), "mac-client-1")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer api-secret")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(Self.bodyData(from: captured))) as? NSDictionary
        )
        XCTAssertEqual(body, ["workspace_id": "default"] as NSDictionary)
    }

    func testWorkspaceListDecodesTopLevelArray() async throws {
        NativeSessionURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer api-secret")
            return (Self.response(for: request), Data(#"[{"id":"default","name":"Default"}]"#.utf8))
        }

        let workspaces = try await SessionClient(session: makeSession()).listWorkspaces(
            at: try XCTUnwrap(URL(string: "https://control.example.test")),
            apiToken: "api-secret"
        )

        XCTAssertEqual(workspaces.map(\.id), ["default"])
    }

    func testWorkspacePreferencesLoadAndPersistThroughWorkspaceEndpoint() async throws {
        var requests: [URLRequest] = []
        NativeSessionURLProtocol.requestHandler = { request in
            requests.append(request)
            return (Self.response(for: request), Data(Self.preferencesJSON.utf8))
        }
        let client = SessionClient(session: makeSession())
        let origin = try XCTUnwrap(URL(string: "https://control.example.test/base"))

        let loaded = try await client.getWorkspacePreferences(
            at: origin,
            apiToken: "api-secret",
            workspaceID: "default"
        )
        _ = try await client.putWorkspacePreferences(
            loaded,
            at: origin,
            apiToken: "api-secret",
            workspaceID: "default"
        )

        XCTAssertEqual(loaded.shortcuts.map(\.name), ["Docs", "Mail"])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(requests[0].url?.path, "/base/v1/workspaces/default/preferences")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer api-secret")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(Self.bodyData(from: requests[1]))) as? [String: Any]
        )
        XCTAssertEqual(body["search_url"] as? String, "https://duckduckgo.com/?q={query}")
        XCTAssertEqual((body["shortcuts"] as? [[String: Any]])?.map { $0["position"] as? Int }, [0, 1])
        XCTAssertEqual(body["recent_urls"] as? [String], ["https://example.test"])
        XCTAssertNil(body["workspace_id"])
        XCTAssertNil(body["updated_at"])
    }

    func testChromePairingAndHandoffUseScopedWorkspaceEndpoints() async throws {
        var requests: [URLRequest] = []
        NativeSessionURLProtocol.requestHandler = { request in
            requests.append(request)
            switch (request.httpMethod, request.url?.lastPathComponent) {
            case ("POST", "chrome-pairings"):
                return (Self.response(for: request, status: 201), Data(Self.chromePairingJSON.utf8))
            case ("GET", "chrome-handoffs"):
                return (Self.response(for: request), Data("[\(Self.chromeHandoffJSON)]".utf8))
            default:
                return (Self.response(for: request), Data(Self.chromeHandoffJSON.utf8))
            }
        }
        let client = SessionClient(session: makeSession())
        let origin = try XCTUnwrap(URL(string: "https://control.example.test/base"))

        let pairing = try await client.createChromePairing(
            at: origin,
            apiToken: "api-secret",
            workspaceID: "default",
            deviceName: "Jonathan's Chrome"
        )
        let handoffs = try await client.listChromeHandoffs(
            at: origin,
            apiToken: "api-secret",
            workspaceID: "default"
        )
        _ = try await client.updateChromeHandoff(
            at: origin,
            apiToken: "api-secret",
            workspaceID: "default",
            handoffID: handoffs[0].id,
            state: "opened"
        )

        XCTAssertEqual(pairing.deviceName, "Jonathan's Chrome")
        XCTAssertEqual(handoffs.map(\.url), ["https://example.test/work"])
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "PUT"])
        XCTAssertEqual(requests[0].url?.path, "/base/v1/workspaces/default/chrome-pairings")
        XCTAssertEqual(requests[1].url?.path, "/base/v1/workspaces/default/chrome-handoffs")
        XCTAssertEqual(requests[2].url?.path, "/base/v1/workspaces/default/chrome-handoffs/handoff-1")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer api-secret" })
    }

    func testCommandWireValuesMatchControlContract() throws {
        let commands = [
            BrowserCommand(type: .goBack, tabID: "tab-1", expectedRevision: 7),
            BrowserCommand(type: .goForward, tabID: "tab-1", expectedRevision: 7),
            BrowserCommand(type: .newTab, url: "https://www.google.com", expectedRevision: 7),
            BrowserCommand(type: .attach, attachmentID: "attachment-1", expectedRevision: 7),
        ]
        let values = try commands.map { command -> String in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: SessionJSON.encoder.encode(command)) as? [String: Any])
            return try XCTUnwrap(object["type"] as? String)
        }

        XCTAssertEqual(values, ["back", "forward", "create_tab", "stage_attachment"])
        XCTAssertEqual(commands[2].url, "https://www.google.com")
    }

    func testUntitledTabDecodes() throws {
        let payload = Self.sessionJSON.replacingOccurrences(of: "\"title\":\"Example\",", with: "")
        let session = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(payload.utf8))

        XCTAssertNil(session.tabs.first?.title)
    }

    func testEventsReturnsNilForUnchanged204() async throws {
        NativeSessionURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://control.example.test/v1/sessions/session-1/events?after_revision=7"
            )
            return (Self.response(for: request, status: 204), Data())
        }

        let result = try await SessionClient(session: makeSession()).sessionEvents(
            at: try XCTUnwrap(URL(string: "https://control.example.test")),
            apiToken: "api-secret",
            sessionID: "session-1",
            afterRevision: 7
        )

        XCTAssertNil(result)
    }

    func testLeaseRenewalAndCommandCarryBearerAndExpectedRevision() async throws {
        var requests: [URLRequest] = []
        NativeSessionURLProtocol.requestHandler = { request in
            requests.append(request)
            if request.httpMethod == "PUT" {
                return (Self.response(for: request), Data(Self.leaseJSON.utf8))
            }
            return (Self.response(for: request, status: 202), Data(Self.commandJSON.utf8))
        }
        let client = SessionClient(session: makeSession())
        let origin = try XCTUnwrap(URL(string: "https://control.example.test"))

        _ = try await client.renewLease(
            at: origin,
            apiToken: "api-secret",
            sessionID: "session-1",
            leaseID: "lease-1",
            token: "secret"
        )
        _ = try await client.sendCommand(
            at: origin,
            apiToken: "api-secret",
            sessionID: "session-1",
            token: "secret",
            idempotencyKey: "command-1",
            command: BrowserCommand(type: .navigate, tabID: "tab-1", url: "https://example.com", expectedRevision: 7)
        )

        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer api-secret")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Ghostlight-Lease-Token"), "secret")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer api-secret")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-Ghostlight-Lease-Token"), "secret")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Idempotency-Key"), "command-1")
        let command = try JSONSerialization.jsonObject(with: try XCTUnwrap(Self.bodyData(from: requests[1]))) as? [String: Any]
        XCTAssertEqual(command?["type"] as? String, "navigate")
        XCTAssertEqual(command?["expected_revision"] as? Int, 7)
    }

    func testCommandSubmissionDecodesQueuedReceipt() async throws {
        NativeSessionURLProtocol.requestHandler = { request in
            (Self.response(for: request, status: 202), Data(Self.commandJSON.utf8))
        }

        let receipt = try await SessionClient(session: makeSession()).sendCommand(
            at: try XCTUnwrap(URL(string: "https://control.example.test")),
            apiToken: "api-secret",
            sessionID: "session-1",
            token: "secret",
            idempotencyKey: "command-key",
            command: BrowserCommand(type: .reload, tabID: "tab-1", expectedRevision: 7)
        )

        XCTAssertEqual(receipt.id, "command-1")
        XCTAssertEqual(receipt.state, .queued)
    }

    func testMediaReadinessRequiresConnectedPeerAndDecodedFrame() {
        let script = MediaReadinessSignal.userScript

        XCTAssertTrue(script.contains("connectionState === \"connected\""))
        XCTAssertTrue(script.contains("requestVideoFrameCallback"))
        XCTAssertTrue(script.contains("mediaReady"))
        XCTAssertFalse(script.contains("DOMContentLoaded"))
    }

    @MainActor
    func testSettingsMigrateLegacyOriginAndNeverPersistLeaseToken() throws {
        let suite = "Ghostlight.NativeSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://legacy.example.test", forKey: "GhostlightControlPlaneURL")

        let viewModel = SessionViewModel(
            defaults: defaults,
            environment: ["GHOSTLIGHT_API_TOKEN": "memory-only"],
            autoConnect: false
        )

        XCTAssertEqual(viewModel.controlOrigin, "https://legacy.example.test")
        XCTAssertEqual(defaults.string(forKey: "GhostlightControlOrigin"), "https://legacy.example.test")
        XCTAssertNil(defaults.object(forKey: "GhostlightControlPlaneURL"))
        XCTAssertNotNil(defaults.string(forKey: "GhostlightClientID"))
        XCTAssertNil(defaults.object(forKey: "GhostlightLeaseToken"))
        XCTAssertEqual(viewModel.apiToken, "memory-only")
        XCTAssertNil(defaults.object(forKey: "GhostlightAPIToken"))
    }

    @MainActor
    func testConnectFailsClosedWithoutAPIToken() throws {
        let viewModel = SessionViewModel(
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            autoConnect: false
        )
        viewModel.controlOrigin = "https://control.example.test"

        viewModel.connect()

        XCTAssertEqual(viewModel.controlState, .failed("Enter the control API token."))
    }

    @MainActor
    func testConnectNormalizesPaddedAPITokenBeforeStartingRequests() throws {
        let viewModel = SessionViewModel(
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            autoConnect: false
        )
        viewModel.controlOrigin = "https://control.example.test"
        viewModel.apiToken = "  api-secret\n"

        viewModel.connect()

        XCTAssertEqual(viewModel.apiToken, "api-secret")
    }

    func testOmniboxBuildsURLsAndSearches() {
        XCTAssertEqual(SessionViewModel.navigationTarget(for: "openai.com"), "https://openai.com")
        XCTAssertEqual(SessionViewModel.navigationTarget(for: "http://localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(
            SessionViewModel.navigationTarget(for: "remote browser performance"),
            "https://www.google.com/search?q=remote%20browser%20performance"
        )
        XCTAssertNil(SessionViewModel.navigationTarget(for: "   "))
    }

    func testOmniboxUsesWorkspaceSearchTemplate() {
        XCTAssertEqual(
            SessionViewModel.navigationTarget(
                for: "swift url encoding",
                searchURL: "https://duckduckgo.com/?q={query}&source=ghostlight"
            ),
            "https://duckduckgo.com/?q=swift%20url%20encoding&source=ghostlight"
        )
    }

    func testSearchTemplateRequiresOneCredentialFreeHTTPSPlaceholder() {
        XCTAssertTrue(
            WorkspacePreferences.isValidSearchURLTemplate("https://search.example.test/?q={query}")
        )
        XCTAssertFalse(
            WorkspacePreferences.isValidSearchURLTemplate("https://search.example.test/?q=missing")
        )
        XCTAssertFalse(
            WorkspacePreferences.isValidSearchURLTemplate("https://search.example.test/?q={query}&copy={query}")
        )
        XCTAssertFalse(
            WorkspacePreferences.isValidSearchURLTemplate("https://user:secret@search.example.test/?q={query}")
        )
    }

    @MainActor
    func testShortcutReplacementNormalizesOrderingAndPersists() async throws {
        let service = NativeSessionServiceStub(receipts: [])
        let viewModel = try makeControllingViewModel(service: service)
        await viewModel.loadWorkspacePreferences()

        let saved = await viewModel.replaceHomePreferences(
            searchURL: "https://search.example.test/?q={query}",
            shortcuts: [
                WorkspaceShortcut(id: "mail", name: "Team Mail", url: "https://mail.example.test", position: 9),
                WorkspaceShortcut(id: "docs", name: "Runbooks", url: "https://docs.example.test", position: 2),
            ]
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(viewModel.workspacePreferences?.searchURL, "https://search.example.test/?q={query}")
        XCTAssertEqual(viewModel.shortcuts.map(\.name), ["Team Mail", "Runbooks"])
        XCTAssertEqual(viewModel.shortcuts.map(\.position), [0, 1])
        XCTAssertEqual(service.preferenceUpdates.last?.searchURL, "https://search.example.test/?q={query}")
        XCTAssertEqual(service.preferenceUpdates.last?.shortcuts.map(\.position), [0, 1])
    }

    @MainActor
    func testChromeHandoffUsesDeterministicCommandAndResolvesAfterAppliedReceipt() async throws {
        let applied = Self.receipt(
            id: "command-handoff",
            type: .newTab,
            state: .applied,
            url: "https://example.test/work"
        )
        let service = NativeSessionServiceStub(receipts: [applied])
        let viewModel = try makeControllingViewModel(service: service)
        let handoff = try SessionJSON.decoder.decode(ChromeHandoff.self, from: Data(Self.chromeHandoffJSON.utf8))

        viewModel.openChromeHandoff(handoff)
        await service.waitForCommandCount(1)
        await service.waitForHandoffUpdateCount(1)

        XCTAssertEqual(service.commandSubmissions[0].idempotencyKey, "chrome-handoff-handoff-1")
        XCTAssertEqual(service.commandSubmissions[0].command.type, .newTab)
        XCTAssertEqual(service.commandSubmissions[0].command.url, "https://example.test/work")
        XCTAssertEqual(service.handoffUpdates, ["handoff-1:opened"])
    }

    @MainActor
    func testAppliedNavigationAddsDeduplicatedServerBackedRecentAndCapsAtTwenty() async throws {
        let existing = (0..<20).map { "https://\($0).example.test" }
        let preferences = WorkspacePreferences(
            workspaceID: "default",
            searchURL: "https://www.google.com/search?q={query}",
            shortcuts: [],
            recentURLs: existing,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let queued = Self.receipt(
            id: "navigate-1",
            type: .navigate,
            state: .queued,
            url: "https://5.example.test"
        )
        let service = NativeSessionServiceStub(receipts: [queued], preferences: preferences)
        let viewModel = try makeControllingViewModel(service: service)
        await viewModel.loadWorkspacePreferences()

        viewModel.navigate(to: "https://5.example.test")
        await service.waitForCommandCount(1)
        XCTAssertTrue(service.preferenceUpdates.isEmpty)

        var event = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8))
        event.commandReceipts = [
            Self.receipt(
                id: "navigate-1",
                type: .navigate,
                state: .applied,
                url: "https://5.example.test"
            )
        ]
        viewModel.apply(event)
        await service.waitForPreferenceUpdateCount(1)

        XCTAssertEqual(service.preferenceUpdates.last?.recentURLs.first, "https://5.example.test")
        XCTAssertEqual(service.preferenceUpdates.last?.recentURLs.count, 20)
        XCTAssertEqual(service.preferenceUpdates.last?.recentURLs.filter { $0 == "https://5.example.test" }.count, 1)
    }

    @MainActor
    func testCredentialBearingNavigationIsNotPersistedAsRecent() async throws {
        let preferences = WorkspacePreferences(
            workspaceID: "default",
            searchURL: WorkspacePreferences.defaultSearchURL,
            shortcuts: [],
            recentURLs: ["https://safe.example.test", "https://user:secret@example.test/private"],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let applied = Self.receipt(
            id: "navigate-secret",
            type: .navigate,
            state: .applied,
            url: "https://example.test/callback?access_token=secret"
        )
        let service = NativeSessionServiceStub(receipts: [applied], preferences: preferences)
        let viewModel = try makeControllingViewModel(service: service)

        await viewModel.loadWorkspacePreferences()
        XCTAssertEqual(viewModel.recentURLs, ["https://safe.example.test"])

        viewModel.navigate(to: "https://example.test/callback?access_token=secret")
        await service.waitForCommandCount(1)
        await Task.yield()

        XCTAssertTrue(service.preferenceUpdates.isEmpty)
        XCTAssertEqual(viewModel.recentURLs, ["https://safe.example.test"])
    }

    func testViewerProcessRecoveryBudgetIsBoundedAndResetsAfterSuccess() {
        var budget = ViewerProcessRecoveryBudget(maximumAttempts: 2, window: 30)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(budget.consume(at: start))
        XCTAssertTrue(budget.consume(at: start.addingTimeInterval(1)))
        XCTAssertFalse(budget.consume(at: start.addingTimeInterval(2)))

        budget.reset()
        XCTAssertTrue(budget.consume(at: start.addingTimeInterval(3)))
        XCTAssertTrue(budget.consume(at: start.addingTimeInterval(40)))
    }

    func testStreamHandoffUsesScopedCapabilityAndFallsBackForRollingOldServer() async throws {
        let connection = StreamConnection(
            id: "stream-1",
            url: try XCTUnwrap(URL(string: "https://old-viewer.example.test")),
            state: "connecting",
            expiresAt: Date(timeIntervalSince1970: 2_000),
            capability: "scoped-capability"
        )
        let bootstrap = ViewerBootstrap(
            streamID: "stream-1",
            viewerURL: try XCTUnwrap(URL(string: "https://scoped-viewer.example.test")),
            viewerCredential: ViewerCredential(type: "cookie", name: "neko-session", value: "ephemeral-secret", path: "/", secure: false, httpOnly: true, sameSite: "strict", expiresAt: Date(timeIntervalSince1970: 2_000)),
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )

        let resolved = try await StreamHandoff.resolve(connection: connection) { capability in
            XCTAssertEqual(capability, "scoped-capability")
            return bootstrap
        }
        XCTAssertEqual(resolved, bootstrap)

        let rollingFallback = try await StreamHandoff.resolve(connection: connection) { _ in
            throw SessionClientError.server(statusCode: 404, message: nil)
        }
        XCTAssertNil(rollingFallback)
        let oldShapeFallback = try await StreamHandoff.resolve(connection: connection) { _ in
            throw DecodingError.keyNotFound(
                ViewerBootstrap.CodingKeys.viewerCredential,
                .init(codingPath: [], debugDescription: "old server returned viewer_password")
            )
        }
        XCTAssertNil(oldShapeFallback)

        let legacy = StreamConnection(
            id: "stream-legacy",
            url: connection.url,
            state: "ready",
            expiresAt: connection.expiresAt
        )
        let legacyFallback = try await StreamHandoff.resolve(connection: legacy) { _ in
            XCTFail("Legacy stream must not attempt capability redemption")
            return bootstrap
        }
        XCTAssertNil(legacyFallback)
    }

    @MainActor
    func testMonotonicSessionApplicationAndFocusedDraftProtection() throws {
        let viewModel = SessionViewModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), autoConnect: false)
        var initial = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8))
        viewModel.apply(initial)
        viewModel.setAddressFocused(true)
        viewModel.addressDraft = "typing.example"

        initial.revision = 6
        initial.tabs[0].url = "https://stale.example"
        viewModel.apply(initial)
        XCTAssertEqual(viewModel.session?.revision, 7)

        initial.revision = 8
        initial.tabs[0].url = "https://new.example"
        viewModel.apply(initial)
        XCTAssertEqual(viewModel.session?.revision, 8)
        XCTAssertEqual(viewModel.addressDraft, "typing.example")

        viewModel.setAddressFocused(false)
        XCTAssertEqual(viewModel.addressDraft, "https://new.example")
    }

    @MainActor
    func testActiveTabChangeReplacesFocusedAddressDraft() throws {
        let viewModel = SessionViewModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), autoConnect: false)
        var session = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8))
        viewModel.apply(session)
        viewModel.setAddressFocused(true)
        viewModel.addressDraft = "unfinished.example"

        session.revision += 1
        session.tabs[0].active = false
        session.tabs.append(
            BrowserTab(
                id: "tab-2",
                title: "Second tab",
                url: "https://second.example",
                active: true,
                loading: false,
                faviconURL: nil
            )
        )
        session.activeTabID = "tab-2"
        viewModel.apply(session)

        XCTAssertEqual(viewModel.addressDraft, "https://second.example")
    }

    @MainActor
    func testCommandsRequireUnexpiredControllerLease() throws {
        let viewModel = SessionViewModel(
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            now: { Date(timeIntervalSince1970: 1_000) },
            autoConnect: false
        )
        XCTAssertFalse(viewModel.canControl)
        viewModel.installLease(try SessionJSON.decoder.decode(ControllerLease.self, from: Data(Self.leaseJSON.utf8)))
        XCTAssertTrue(viewModel.canControl)
        viewModel.becomeObserver()
        XCTAssertFalse(viewModel.canControl)
    }

    @MainActor
    func testQueuedReceiptTransitionsToAppliedAtSameSessionRevision() async throws {
        let service = NativeSessionServiceStub(receipts: [Self.queuedReceipt])
        let viewModel = try makeControllingViewModel(service: service)

        viewModel.perform(.reload)
        await service.waitForCommandCount(1)
        await Task.yield()
        XCTAssertEqual(viewModel.commandStatus, .pending(1))

        var event = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8))
        event.commandReceipts = [Self.appliedReceipt]
        viewModel.apply(event)

        XCTAssertEqual(viewModel.commandStatus, .idle)
    }

    @MainActor
    func testQueuedReceiptTransitionsToFailedAndRetryUsesFreshSubmissionAtCurrentRevision() async throws {
        let retryApplied = Self.receipt(
            id: "command-2",
            sequence: 2,
            type: .goBack,
            state: .applied,
            expectedRevision: 8
        )
        let service = NativeSessionServiceStub(receipts: [Self.queuedReceipt, retryApplied])
        let viewModel = try makeControllingViewModel(service: service)

        viewModel.perform(.goBack)
        await service.waitForCommandCount(1)
        await Task.yield()
        var event = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8))
        event.revision = 8
        event.commandReceipts = [Self.failedReceipt]
        viewModel.apply(event)

        XCTAssertEqual(
            viewModel.commandStatus,
            .failed(code: "navigation_failed", message: "History entry unavailable")
        )

        viewModel.retryFailedCommand()
        await service.waitForCommandCount(2)
        await Task.yield()
        let submissions = service.commandSubmissions
        XCTAssertNotEqual(submissions[0].idempotencyKey, submissions[1].idempotencyKey)
        XCTAssertEqual(submissions[1].command.expectedRevision, 8)
        XCTAssertEqual(submissions.map(\.command.type), [.goBack, .goBack])
        XCTAssertEqual(viewModel.commandStatus, .idle)
    }

    @MainActor
    func testLaterAppliedReceiptSupersedesHistoricalFailure() async throws {
        let laterApplied = Self.receipt(id: "command-2", sequence: 2, type: .goBack, state: .applied)
        let service = NativeSessionServiceStub(receipts: [Self.queuedReceipt, laterApplied])
        let viewModel = try makeControllingViewModel(service: service)

        viewModel.perform(.goBack)
        await service.waitForCommandCount(1)
        var event = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8))
        event.commandReceipts = [Self.failedReceipt]
        viewModel.apply(event)

        viewModel.retryFailedCommand()
        await service.waitForCommandCount(2)
        await Task.yield()

        event.commandReceipts = [Self.failedReceipt, laterApplied]
        viewModel.apply(event)
        XCTAssertEqual(viewModel.commandStatus, .idle)
    }

    @MainActor
    func testNativeCommandActionsRouteExactlyOnceAndCycleTabs() async throws {
        let service = NativeSessionServiceStub(receipts: Self.routableActions.enumerated().map { index, action in
            Self.receipt(id: "command-\(index)", type: action.expectedCommandType, state: .queued)
        })
        let viewModel = try makeControllingViewModel(service: service, includeSecondTab: true)

        for action in Self.routableActions {
            viewModel.perform(action)
        }
        await service.waitForCommandCount(Self.routableActions.count)

        XCTAssertEqual(
            service.commandSubmissions.map(\.command.type.rawValue).sorted(),
            Self.routableActions.map(\.expectedCommandType.rawValue).sorted()
        )
        XCTAssertEqual(service.commandSubmissions.count, Self.routableActions.count)
        viewModel.perform(.focusLocation)
        XCTAssertEqual(viewModel.addressFocusRequest, 1)
        XCTAssertEqual(service.commandSubmissions.count, Self.routableActions.count)
    }

    @MainActor
    func testObserverNativeCommandActionsDoNotSubmit() async throws {
        let service = NativeSessionServiceStub(receipts: [])
        let viewModel = SessionViewModel(
            client: service,
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            autoConnect: false
        )
        viewModel.apply(try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8)))
        viewModel.becomeObserver()

        NativeBrowserAction.allCases.forEach(viewModel.perform)
        await Task.yield()

        XCTAssertTrue(service.commandSubmissions.isEmpty)
        XCTAssertEqual(viewModel.addressFocusRequest, 0)
    }

    @MainActor
    private func makeControllingViewModel(
        service: NativeSessionServiceStub,
        includeSecondTab: Bool = false
    ) throws -> SessionViewModel {
        let viewModel = SessionViewModel(
            client: service,
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
            now: { Date(timeIntervalSince1970: 1_000) },
            autoConnect: false
        )
        var session = try SessionJSON.decoder.decode(BrowserSession.self, from: Data(Self.sessionJSON.utf8))
        if includeSecondTab {
            session.tabs.append(
                BrowserTab(id: "tab-2", title: "Second", url: "https://second.example", active: false, loading: false, faviconURL: nil)
            )
        }
        viewModel.controlOrigin = "https://control.example.test"
        viewModel.apiToken = "api-secret"
        viewModel.apply(session)
        viewModel.installLease(try SessionJSON.decoder.decode(ControllerLease.self, from: Data(Self.leaseJSON.utf8)))
        return viewModel
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeSessionURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(for request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }

    private static func bodyData(from request: URLRequest?) -> Data? {
        guard let request else { return nil }
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            data.append(bytes, count: count)
        }
        return data
    }

    private static let sessionJSON = #"""
    {
      "id":"session-1","workspace_id":"default","name":"Browser","revision":7,
      "runtime_state":"ready","tabs":[{"id":"tab-1","title":"Example","url":"https://example.com","active":true,"loading":false,"audible":false,"discarded":false,"window_id":1,"index":0}],
      "active_tab_id":"tab-1","controller":null,"stream":null,
      "created_at":"2026-08-13T12:00:00Z","updated_at":"2026-08-13T12:00:01Z"
    }
    """#

    private static let leaseJSON = #"""
    {
      "id":"lease-1","session_id":"session-1","client_id":"mac","token":"secret","epoch":2,
      "expires_at":"2030-08-13T12:00:30Z","renew_after":"2030-08-13T12:00:10Z"
    }
    """#

    private static let commandJSON = #"""
    {
      "id":"command-1","sequence":1,"session_id":"session-1","type":"navigate",
      "url":"https://example.com","tab_id":"tab-1","expected_revision":7,
      "lease_epoch":2,"state":"queued","created_at":"2026-08-13T12:00:02Z"
    }
    """#

    private static let preferencesJSON = #"""
    {
      "workspace_id":"default","search_url":"https://duckduckgo.com/?q={query}",
      "shortcuts":[
        {"id":"docs","name":"Docs","url":"https://developer.apple.com","position":0},
        {"id":"mail","name":"Mail","url":"https://mail.example.test","position":1}
      ],
      "recent_urls":["https://example.test"],"updated_at":"2026-08-13T12:00:00Z"
    }
    """#

    private static let chromePairingJSON = #"""
    {
      "pairing_code":"pairing-code","workspace_id":"default",
      "device_name":"Jonathan's Chrome","expires_at":"2026-08-13T12:10:00Z"
    }
    """#

    private static let chromeHandoffJSON = #"""
    {
      "id":"handoff-1","workspace_id":"default","device_id":"device-1",
      "device_name":"Jonathan's Chrome","title":"Work","url":"https://example.test/work",
      "state":"pending","created_at":"2026-08-13T12:00:00Z","updated_at":"2026-08-13T12:00:00Z"
    }
    """#

    private static let queuedReceipt = receipt(id: "command-1", type: .reload, state: .queued)
    private static let appliedReceipt = receipt(id: "command-1", type: .reload, state: .applied)
    private static let failedReceipt = receipt(
        id: "command-1",
        type: .goBack,
        state: .failed,
        errorCode: "navigation_failed",
        error: "History entry unavailable"
    )
    private static let routableActions: [NativeBrowserAction] = [
        .newTab, .closeTab, .reload, .goBack, .goForward, .nextTab, .previousTab,
    ]

    private static func receipt(
        id: String,
        sequence: Int = 1,
        type: BrowserCommandType,
        state: CommandReceiptState,
        url: String? = nil,
        expectedRevision: Int = 7,
        errorCode: String? = nil,
        error: String? = nil
    ) -> CommandReceipt {
        CommandReceipt(
            id: id,
            sequence: sequence,
            sessionID: "session-1",
            type: type,
            url: url,
            tabID: "tab-1",
            attachmentID: nil,
            expectedRevision: expectedRevision,
            leaseEpoch: 2,
            state: state,
            errorCode: errorCode,
            error: error,
            result: nil,
            resultingRevision: state == .queued ? nil : 8,
            acknowledgedAt: nil,
            completedAt: state == .queued ? nil : Date(timeIntervalSince1970: 1_001),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private extension NativeBrowserAction {
    var expectedCommandType: BrowserCommandType {
        switch self {
        case .newTab: .newTab
        case .closeTab: .closeTab
        case .reload: .reload
        case .goBack: .goBack
        case .goForward: .goForward
        case .nextTab, .previousTab: .activateTab
        case .focusLocation: fatalError("Focus Location does not submit a browser command")
        }
    }
}

private final class NativeSessionServiceStub: SessionServicing, @unchecked Sendable {
    struct Submission {
        let idempotencyKey: String
        let command: BrowserCommand
    }

    private let lock = NSLock()
    private var receipts: [CommandReceipt]
    private var submissions: [Submission] = []
    private var preferences: WorkspacePreferences
    private var updates: [WorkspacePreferences] = []
    private var resolvedHandoffs: [String] = []

    init(receipts: [CommandReceipt], preferences: WorkspacePreferences? = nil) {
        self.receipts = receipts
        self.preferences = preferences ?? WorkspacePreferences(
            workspaceID: "default",
            searchURL: "https://www.google.com/search?q={query}",
            shortcuts: [],
            recentURLs: [],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    var commandSubmissions: [Submission] {
        lock.withLock { submissions }
    }

    var preferenceUpdates: [WorkspacePreferences] {
        lock.withLock { updates }
    }

    var handoffUpdates: [String] {
        lock.withLock { resolvedHandoffs }
    }

    func waitForCommandCount(_ count: Int) async {
        for _ in 0..<100 where commandSubmissions.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForPreferenceUpdateCount(_ count: Int) async {
        for _ in 0..<100 where preferenceUpdates.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForHandoffUpdateCount(_ count: Int) async {
        for _ in 0..<100 where handoffUpdates.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func getSession(at origin: URL, apiToken: String, sessionID: String) async throws -> BrowserSession { fatalError() }
    func createSession(at origin: URL, apiToken: String, idempotencyKey: String) async throws -> BrowserSession { fatalError() }
    func sessionEvents(at origin: URL, apiToken: String, sessionID: String, afterRevision: Int) async throws -> BrowserSession? { nil }
    func acquireLease(at origin: URL, apiToken: String, sessionID: String, clientID: String) async throws -> ControllerLease { fatalError() }
    func renewLease(at origin: URL, apiToken: String, sessionID: String, leaseID: String, token: String) async throws -> ControllerLease { fatalError() }
    func releaseLease(at origin: URL, apiToken: String, sessionID: String, leaseID: String, token: String) async throws {}
    func uploadAttachment(at origin: URL, apiToken: String, sessionID: String, token: String, fileURL: URL) async throws -> Attachment { fatalError() }
    func createStream(at origin: URL, apiToken: String, sessionID: String, clientID: String) async throws -> StreamConnection { fatalError() }
    func redeemViewerCapability(at origin: URL, capability: String, clientID: String) async throws -> ViewerBootstrap { fatalError() }
    func getWorkspacePreferences(at origin: URL, apiToken: String, workspaceID: String) async throws -> WorkspacePreferences {
        lock.withLock { preferences }
    }
    func putWorkspacePreferences(_ preferences: WorkspacePreferences, at origin: URL, apiToken: String, workspaceID: String) async throws -> WorkspacePreferences {
        lock.withLock {
            self.preferences = preferences
            updates.append(preferences)
            return preferences
        }
    }
    func createChromePairing(at origin: URL, apiToken: String, workspaceID: String, deviceName: String) async throws -> ChromePairing { fatalError() }
    func listChromeHandoffs(at origin: URL, apiToken: String, workspaceID: String) async throws -> [ChromeHandoff] { [] }
    func updateChromeHandoff(at origin: URL, apiToken: String, workspaceID: String, handoffID: String, state: String) async throws -> ChromeHandoff {
        lock.withLock { resolvedHandoffs.append("\(handoffID):\(state)") }
        return ChromeHandoff(
            id: handoffID,
            workspaceID: workspaceID,
            deviceID: "device-1",
            deviceName: "Chrome",
            title: "Work",
            url: "https://example.test/work",
            state: state,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001)
        )
    }
    func listChromeDevices(at origin: URL, apiToken: String, workspaceID: String) async throws -> [ChromeDevice] { [] }
    func revokeChromeDevice(at origin: URL, apiToken: String, workspaceID: String, deviceID: String) async throws {}

    func sendCommand(
        at origin: URL,
        apiToken: String,
        sessionID: String,
        token: String,
        idempotencyKey: String,
        command: BrowserCommand
    ) async throws -> CommandReceipt {
        lock.withLock {
            submissions.append(.init(idempotencyKey: idempotencyKey, command: command))
            return receipts.removeFirst()
        }
    }
}

private final class NativeSessionURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.requestHandler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
