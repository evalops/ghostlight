import Foundation
import XCTest
@testable import GhostlightApp

final class SessionClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDiscoverViewerUsesStatelessGETRequest() async throws {
        let expectedResponse = Data(#"{"viewer_url":"http://localhost:6080/viewer"}"#.utf8)
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        StubURLProtocol.requestHandler = { request in
            capturedRequest = request
            capturedBody = Self.bodyData(from: request)
            return (try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )), expectedResponse)
        }

        let client = SessionClient(session: makeStubSession())
        let response = try await client.discoverViewer(
            at: try XCTUnwrap(URL(string: "http://localhost:8080"))
        )

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "http://localhost:8080/v1/viewer")
        XCTAssertEqual(capturedRequest?.timeoutInterval, SessionClient.discoveryRequestTimeout)
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(capturedBody)
        XCTAssertEqual(response.viewerURL.absoluteString, "http://localhost:6080/viewer")
    }

    func testDiscoverViewerAppendsEndpointToControlPlanePathAndPreservesQuery() async throws {
        let expectedResponse = Data(#"{"viewer_url":"http://localhost:6080/viewer"}"#.utf8)
        var capturedRequest: URLRequest?
        StubURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )), expectedResponse)
        }

        let client = SessionClient(session: makeStubSession())
        _ = try await client.discoverViewer(
            at: try XCTUnwrap(URL(string: "http://localhost:8080/control?token=abc"))
        )

        XCTAssertEqual(
            capturedRequest?.url?.absoluteString,
            "http://localhost:8080/control/v1/viewer?token=abc"
        )
        XCTAssertEqual(capturedRequest?.timeoutInterval, SessionClient.discoveryRequestTimeout)
    }

    func testDiscoverViewerRejectsOversizedResponseBody() async throws {
        let oversizedBody = Data(repeating: 0x20, count: SessionClient.maxDiscoveryResponseBytes + 1)
        StubURLProtocol.requestHandler = { request in
            (try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )), oversizedBody)
        }

        let client = SessionClient(session: makeStubSession())
        do {
            _ = try await client.discoverViewer(
                at: try XCTUnwrap(URL(string: "http://localhost:8080"))
            )
            XCTFail("Expected an invalidResponse error for an oversized body")
        } catch {
            XCTAssertEqual(error as? SessionClientError, .invalidResponse)
        }
    }

    func testDiscoverViewerRejectsUnsupportedViewerURL() async throws {
        let expectedResponse = Data(#"{"viewer_url":"ftp://viewer.example.test/viewer"}"#.utf8)
        StubURLProtocol.requestHandler = { request in
            (try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )), expectedResponse)
        }

        let client = SessionClient(session: makeStubSession())
        do {
            _ = try await client.discoverViewer(
                at: try XCTUnwrap(URL(string: "http://localhost:8080"))
            )
            XCTFail("Expected an invalidViewerURL error")
        } catch {
            XCTAssertEqual(error as? SessionClientError, .invalidViewerURL)
        }
    }

    func testViewerDiscoveryResponseDecodesViewerURL() throws {
        let data = Data(#"{"viewer_url":"https://ghostlight.example/viewer?session=abc"}"#.utf8)

        let response = try JSONDecoder().decode(ViewerDiscoveryResponse.self, from: data)

        XCTAssertEqual(
            response.viewerURL,
            try XCTUnwrap(URL(string: "https://ghostlight.example/viewer?session=abc"))
        )
    }

    func testControlPlaneURLValidationTrimsAndAcceptsHTTPAndHTTPS() throws {
        let httpURL = try ControlPlaneURLValidator.validate("  http://localhost:8080  ")
        let httpsURL = try ControlPlaneURLValidator.validate("https://ghostlight.example/control")

        XCTAssertEqual(httpURL.absoluteString, "http://localhost:8080")
        XCTAssertEqual(httpsURL.absoluteString, "https://ghostlight.example/control")
    }

    func testControlPlaneURLValidationRejectsInvalidInput() {
        XCTAssertThrowsError(try ControlPlaneURLValidator.validate("")) { error in
            XCTAssertEqual(error as? ControlPlaneURLError, .empty)
        }
        XCTAssertThrowsError(try ControlPlaneURLValidator.validate("ftp://localhost:8080")) { error in
            XCTAssertEqual(error as? ControlPlaneURLError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try ControlPlaneURLValidator.validate("http:///v1")) { error in
            XCTAssertEqual(error as? ControlPlaneURLError, .missingHost)
        }
        XCTAssertThrowsError(try ControlPlaneURLValidator.validate("http://user:password@localhost:8080")) { error in
            XCTAssertEqual(error as? ControlPlaneURLError, .credentialsNotAllowed)
        }
    }

    func testHTTPErrorMappingPreservesStatusAndServerMessage() {
        let error = SessionClientError.mapHTTPFailure(
            statusCode: 503,
            data: Data(#"{"error":{"code":"internal_error","message":"session capacity exhausted"}}"#.utf8)
        )

        XCTAssertEqual(
            error,
            .server(statusCode: 503, message: "session capacity exhausted")
        )
    }

    func testTransportErrorMappingRecognizesOfflineNetwork() throws {
        let error = try SessionClientError.mapTransportError(URLError(.notConnectedToInternet))

        XCTAssertEqual(error, .networkUnavailable)
    }

    func testTransportErrorMappingRethrowsCancellation() {
        XCTAssertThrowsError(try SessionClientError.mapTransportError(URLError(.cancelled))) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testViewModelPersistsSuccessfulControlPlaneAndReconnectsOnRelaunch() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstClient = StubViewerDiscovering(
            response: ViewerDiscoveryResponse(
                viewerURL: try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
            )
        )
        let firstLaunch = SessionViewModel(
            client: firstClient,
            defaults: defaults,
            autoConnect: false
        )
        firstLaunch.controlPlaneURL = "http://control.example.test:8080"
        firstLaunch.connect()

        await fulfillment(of: [firstClient.requestExpectation], timeout: 1)
        await waitUntil { firstLaunch.viewerURL != nil }

        let relaunchClient = StubViewerDiscovering(
            response: ViewerDiscoveryResponse(
                viewerURL: try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
            )
        )
        let relaunched = SessionViewModel(
            client: relaunchClient,
            defaults: defaults,
            autoConnect: true
        )

        await fulfillment(of: [relaunchClient.requestExpectation], timeout: 1)
        await waitUntil { relaunched.viewerURL != nil }
        XCTAssertEqual(relaunched.controlPlaneURL, "http://control.example.test:8080")
        XCTAssertEqual(relaunchClient.requestedURLs, ["http://control.example.test:8080"])
    }

    @MainActor
    func testViewModelEnvironmentURLOverridesSavedURLAndReconnects() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://saved.example.test:8080", forKey: "GhostlightControlPlaneURL")

        let client = StubViewerDiscovering(
            response: ViewerDiscoveryResponse(
                viewerURL: try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
            )
        )
        let viewModel = SessionViewModel(
            client: client,
            defaults: defaults,
            environment: ["GHOSTLIGHT_CONTROL_URL": "http://environment.example.test:8080"],
            autoConnect: true
        )

        await fulfillment(of: [client.requestExpectation], timeout: 1)
        await waitUntil { viewModel.viewerURL != nil }
        XCTAssertEqual(viewModel.controlPlaneURL, "http://environment.example.test:8080")
        XCTAssertEqual(client.requestedURLs, ["http://environment.example.test:8080"])
    }

    @MainActor
    func testViewerNavigationTransitionsAndBoundedAutomaticRetry() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://saved.example.test:8080", forKey: "GhostlightControlPlaneURL")

        let viewerURL = try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
        let client = StubViewerDiscovering(response: ViewerDiscoveryResponse(viewerURL: viewerURL))
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: true)

        await fulfillment(of: [client.requestExpectation], timeout: 1)
        await waitUntil { viewModel.state == .loadingViewer(viewerURL, retryAttempt: 0) }

        viewModel.viewerNavigationStarted()
        XCTAssertEqual(viewModel.state, .loadingViewer(viewerURL, retryAttempt: 0))
        viewModel.viewerNavigationFailed("synthetic navigation failure")
        XCTAssertEqual(viewModel.state, .loadingViewer(viewerURL, retryAttempt: 1))
        XCTAssertEqual(viewModel.reloadToken, 0)
        await waitUntil(timeout: 3) { viewModel.reloadToken == 1 }
        viewModel.viewerNavigationFailed("synthetic navigation failure")
        XCTAssertEqual(viewModel.state, .loadingViewer(viewerURL, retryAttempt: 2))
        await waitUntil(timeout: 4) { viewModel.reloadToken == 2 }
        viewModel.viewerNavigationFailed("synthetic navigation failure")
        XCTAssertEqual(
            viewModel.state,
            .viewerFailed(viewerURL, message: "synthetic navigation failure")
        )

        viewModel.retryViewer()
        XCTAssertEqual(viewModel.state, .loadingViewer(viewerURL, retryAttempt: 0))
        viewModel.viewerNavigationFinished(at: viewerURL)
        XCTAssertEqual(viewModel.state, .viewerLoaded(viewerURL))
    }

    @MainActor
    func testExplicitRetryDoesNotRestartAutomaticRetryLoop() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewerURL = try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
        let client = StubViewerDiscovering(response: ViewerDiscoveryResponse(viewerURL: viewerURL))
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: false)
        viewModel.controlPlaneURL = "http://control.example.test:8080"
        viewModel.connect()

        await fulfillment(of: [client.requestExpectation], timeout: 1)
        await waitUntil { viewModel.state == .loadingViewer(viewerURL, retryAttempt: 0) }
        viewModel.viewerNavigationFailed("first failure")
        XCTAssertEqual(viewModel.state, .viewerFailed(viewerURL, message: "first failure"))
        viewModel.retryViewer()
        viewModel.viewerNavigationFailed("second failure")
        XCTAssertEqual(viewModel.state, .viewerFailed(viewerURL, message: "second failure"))
    }

    @MainActor
    func testReloadReportsLoadingUntilNavigationFinishes() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewerURL = try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
        let client = StubViewerDiscovering(response: ViewerDiscoveryResponse(viewerURL: viewerURL))
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: false)
        viewModel.connect()

        await fulfillment(of: [client.requestExpectation], timeout: 1)
        await waitUntil { viewModel.state == .loadingViewer(viewerURL, retryAttempt: 0) }
        viewModel.viewerNavigationFinished(at: viewerURL)
        XCTAssertEqual(viewModel.state, .viewerLoaded(viewerURL))

        viewModel.reloadViewer()
        viewModel.viewerNavigationStarted()

        XCTAssertEqual(viewModel.state, .loadingViewer(viewerURL, retryAttempt: 0))
    }

    @MainActor
    func testFinishedSameOriginRedirectKeepsDiscoveredViewerEntryURL() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewerURL = try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
        let redirectedURL = try XCTUnwrap(URL(string: "http://viewer.example.test:8081/login"))
        let client = StubViewerDiscovering(response: ViewerDiscoveryResponse(viewerURL: viewerURL))
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: false)
        viewModel.connect()

        await fulfillment(of: [client.requestExpectation], timeout: 1)
        await waitUntil { viewModel.state == .loadingViewer(viewerURL, retryAttempt: 0) }
        viewModel.viewerNavigationFinished(at: redirectedURL)

        XCTAssertEqual(viewModel.state, .viewerLoaded(viewerURL))
        XCTAssertEqual(viewModel.viewerURL, viewerURL)
    }

    @MainActor
    func testFinishedCrossOriginRedirectFailsViewerLoad() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewerURL = try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://attacker.example.test/login"))
        let client = StubViewerDiscovering(response: ViewerDiscoveryResponse(viewerURL: viewerURL))
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: false)
        viewModel.connect()

        await fulfillment(of: [client.requestExpectation], timeout: 1)
        await waitUntil { viewModel.state == .loadingViewer(viewerURL, retryAttempt: 0) }
        viewModel.viewerNavigationFinished(at: redirectedURL)

        XCTAssertEqual(
            viewModel.state,
            .viewerFailed(viewerURL, message: "The viewer navigated to an unexpected origin.")
        )
        XCTAssertEqual(viewModel.viewerURL, viewerURL)
    }

    @MainActor
    func testCancelledDiscoveryCannotOverwriteDisconnectWithFailure() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let client = CancellationIgnoringViewerDiscovering()
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: false)
        viewModel.connect()
        await fulfillment(of: [client.requestExpectation], timeout: 1)

        viewModel.disconnect()
        await fulfillment(of: [client.completionExpectation], timeout: 1)
        await Task.yield()

        XCTAssertEqual(viewModel.state, .disconnected)
        XCTAssertNil(defaults.string(forKey: "GhostlightControlPlaneURL"))
    }

    @MainActor
    func testNewConnectionCannotBeOverwrittenByCancelledRequest() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewerURL = try XCTUnwrap(URL(string: "http://new-viewer.example.test:8081"))
        let client = SupersededViewerDiscovering(
            newResponse: ViewerDiscoveryResponse(viewerURL: viewerURL)
        )
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: false)
        viewModel.controlPlaneURL = "http://old-control.example.test:8080"
        viewModel.connect()
        await fulfillment(of: [client.oldRequestExpectation], timeout: 1)

        viewModel.controlPlaneURL = "http://new-control.example.test:8080"
        viewModel.connect()
        await fulfillment(of: [client.newRequestExpectation], timeout: 1)
        await waitUntil { viewModel.state == .loadingViewer(viewerURL, retryAttempt: 0) }
        await fulfillment(of: [client.oldCompletionExpectation], timeout: 1)
        await Task.yield()

        XCTAssertEqual(viewModel.state, .loadingViewer(viewerURL, retryAttempt: 0))
        XCTAssertEqual(viewModel.viewerURL, viewerURL)
        XCTAssertEqual(
            defaults.string(forKey: "GhostlightControlPlaneURL"),
            "http://new-control.example.test:8080"
        )
    }

    @MainActor
    func testViewerFailureAfterSuccessfulLoadReportsFailure() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewerURL = try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
        let client = StubViewerDiscovering(response: ViewerDiscoveryResponse(viewerURL: viewerURL))
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: false)
        viewModel.connect()
        await fulfillment(of: [client.requestExpectation], timeout: 1)
        await waitUntil { viewModel.state == .loadingViewer(viewerURL, retryAttempt: 0) }
        viewModel.viewerNavigationFinished(at: viewerURL)

        viewModel.viewerNavigationFailed("The viewer process stopped unexpectedly.")

        XCTAssertEqual(
            viewModel.state,
            .viewerFailed(viewerURL, message: "The viewer process stopped unexpectedly.")
        )
    }

    func testNavigationCancellationIsNotPresentedAsViewerFailure() {
        XCTAssertFalse(
            ViewerWebView.Coordinator.shouldReportNavigationError(URLError(.cancelled))
        )
        XCTAssertTrue(
            ViewerWebView.Coordinator.shouldReportNavigationError(URLError(.cannotConnectToHost))
        )
    }

    func testNavigationPolicyRequiresMatchingSchemeHostAndPort() throws {
        let origin = try XCTUnwrap(URL(string: "http://viewer.example.test:8081/viewer"))

        XCTAssertTrue(
            ViewerWebView.Coordinator.isSameOrigin(
                try XCTUnwrap(URL(string: "http://viewer.example.test:8081/login")),
                as: origin
            )
        )
        XCTAssertFalse(
            ViewerWebView.Coordinator.isSameOrigin(
                try XCTUnwrap(URL(string: "https://viewer.example.test:8081/login")),
                as: origin
            )
        )
        XCTAssertFalse(
            ViewerWebView.Coordinator.isSameOrigin(
                try XCTUnwrap(URL(string: "http://attacker.example.test:8081/login")),
                as: origin
            )
        )
        XCTAssertFalse(
            ViewerWebView.Coordinator.isSameOrigin(
                try XCTUnwrap(URL(string: "http://viewer.example.test:9090/login")),
                as: origin
            )
        )
    }

    @MainActor
    func testDisconnectClearsSavedAutomaticConnection() async throws {
        let suiteName = "GhostlightAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://saved.example.test:8080", forKey: "GhostlightControlPlaneURL")

        let client = StubViewerDiscovering(
            response: ViewerDiscoveryResponse(
                viewerURL: try XCTUnwrap(URL(string: "http://viewer.example.test:8081"))
            )
        )
        let viewModel = SessionViewModel(client: client, defaults: defaults, autoConnect: false)
        viewModel.disconnect()

        XCTAssertNil(defaults.string(forKey: "GhostlightControlPlaneURL"))
        XCTAssertEqual(viewModel.state, .disconnected)
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private final class StubViewerDiscovering: ViewerDiscovering, @unchecked Sendable {
    let requestExpectation = XCTestExpectation(description: "viewer discovery")
    private let response: ViewerDiscoveryResponse
    private(set) var requestedURLs: [String] = []

    init(response: ViewerDiscoveryResponse) {
        self.response = response
    }

    func discoverViewer(controlPlaneURL: String) async throws -> ViewerDiscoveryResponse {
        requestedURLs.append(controlPlaneURL)
        requestExpectation.fulfill()
        return response
    }
}

private final class CancellationIgnoringViewerDiscovering: ViewerDiscovering, @unchecked Sendable {
    let requestExpectation = XCTestExpectation(description: "viewer discovery requested")
    let completionExpectation = XCTestExpectation(description: "viewer discovery completed")

    func discoverViewer(controlPlaneURL: String) async throws -> ViewerDiscoveryResponse {
        requestExpectation.fulfill()
        do {
            try await Task.sleep(for: .milliseconds(20))
        } catch {
            // Model a transport that maps cancellation to its own domain error.
        }
        completionExpectation.fulfill()
        throw SessionClientError.networkUnavailable
    }
}

private final class SupersededViewerDiscovering: ViewerDiscovering, @unchecked Sendable {
    let oldRequestExpectation = XCTestExpectation(description: "old viewer discovery requested")
    let newRequestExpectation = XCTestExpectation(description: "new viewer discovery requested")
    let oldCompletionExpectation = XCTestExpectation(description: "old viewer discovery completed")
    private let newResponse: ViewerDiscoveryResponse

    init(newResponse: ViewerDiscoveryResponse) {
        self.newResponse = newResponse
    }

    func discoverViewer(controlPlaneURL: String) async throws -> ViewerDiscoveryResponse {
        if controlPlaneURL.contains("old-control") {
            oldRequestExpectation.fulfill()
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                // Model a transport that finishes after cancellation.
            }
            oldCompletionExpectation.fulfill()
            throw SessionClientError.networkUnavailable
        }

        newRequestExpectation.fulfill()
        return newResponse
    }
}

private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
