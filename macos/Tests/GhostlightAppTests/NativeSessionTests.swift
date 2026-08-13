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
