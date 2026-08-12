import Foundation
import XCTest
@testable import GhostlightApp

final class SessionClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testCreateSessionEncodesEmptyJSONRequest() async throws {
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
        let response = try await client.createSession(
            at: try XCTUnwrap(URL(string: "http://localhost:8080"))
        )

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "http://localhost:8080/v1/sessions")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(capturedBody, Data("{}".utf8))
        XCTAssertEqual(response.viewerURL.absoluteString, "http://localhost:6080/viewer")
    }

    func testCreateSessionResponseDecodesViewerURL() throws {
        let data = Data(#"{"viewer_url":"https://ghostlight.example/viewer?session=abc"}"#.utf8)

        let response = try JSONDecoder().decode(CreateSessionResponse.self, from: data)

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
    }

    func testHTTPErrorMappingPreservesStatusAndServerMessage() {
        let error = SessionClientError.mapHTTPFailure(
            statusCode: 503,
            data: Data(#"{"message":"session capacity exhausted"}"#.utf8)
        )

        XCTAssertEqual(
            error,
            .server(statusCode: 503, message: "session capacity exhausted")
        )
    }

    func testTransportErrorMappingRecognizesOfflineNetwork() {
        let error = SessionClientError.mapTransportError(URLError(.notConnectedToInternet))

        XCTAssertEqual(error, .networkUnavailable)
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
