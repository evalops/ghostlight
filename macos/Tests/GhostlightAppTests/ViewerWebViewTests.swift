import Foundation
import WebKit
import XCTest
@testable import GhostlightApp

final class ViewerWebViewTests: XCTestCase {
    func testViewerCredentialBuildsAnEphemeralCookieWithoutTheGlobalPassword() throws {
        let expiresAt = Date().addingTimeInterval(30)
        let credential = ViewerCredential(
            type: "cookie", name: "neko-session", value: "scoped-value", path: "/",
            secure: true, httpOnly: true, sameSite: "strict", expiresAt: expiresAt
        )
        let cookie = try XCTUnwrap(ViewerWebView.viewerCookie(
            credential,
            for: try XCTUnwrap(URL(string: "https://viewer.example.test/?embed=1"))
        ))

        XCTAssertEqual(cookie.name, "neko-session")
        XCTAssertEqual(cookie.value, "scoped-value")
        XCTAssertEqual(cookie.domain, "viewer.example.test")
        XCTAssertEqual(try XCTUnwrap(cookie.expiresDate).timeIntervalSince(expiresAt), 0, accuracy: 1)
        XCTAssertTrue(cookie.isHTTPOnly)
    }

    func testNavigationOriginRequiresMatchingSchemeHostAndEffectivePort() throws {
        let origin = try XCTUnwrap(URL(string: "https://viewer.example.test"))

        XCTAssertTrue(ViewerWebView.Coordinator.isSameOrigin(
            try XCTUnwrap(URL(string: "https://viewer.example.test/session")),
            as: origin
        ))
        XCTAssertTrue(ViewerWebView.Coordinator.isSameOrigin(
            try XCTUnwrap(URL(string: "https://viewer.example.test:443/session")),
            as: origin
        ))
        XCTAssertFalse(ViewerWebView.Coordinator.isSameOrigin(
            try XCTUnwrap(URL(string: "http://viewer.example.test/session")),
            as: origin
        ))
        XCTAssertFalse(ViewerWebView.Coordinator.isSameOrigin(
            try XCTUnwrap(URL(string: "https://other.example.test/session")),
            as: origin
        ))
        XCTAssertFalse(ViewerWebView.Coordinator.isSameOrigin(
            try XCTUnwrap(URL(string: "https://viewer.example.test:8443/session")),
            as: origin
        ))
    }

    func testMediaCapturePermissionPolicyFailsClosed() {
        XCTAssertEqual(ViewerWebView.PermissionPolicy.mediaCaptureDecision, .deny)
        XCTAssertEqual(ViewerWebView.PermissionPolicy.capabilities(for: .camera), [.camera])
        XCTAssertEqual(ViewerWebView.PermissionPolicy.capabilities(for: .microphone), [.microphone])
        XCTAssertEqual(ViewerWebView.PermissionPolicy.capabilities(for: .cameraAndMicrophone), [.camera, .microphone])
    }

    func testDownloadDestinationSanitizesTraversalAndAvoidsExistingFiles() {
        let directory = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let existing = Set([
            directory.appendingPathComponent("report.pdf").path,
            directory.appendingPathComponent("report-1.pdf").path,
        ])

        let destination = ViewerWebView.DownloadDestination.destination(
            in: directory,
            suggestedFilename: "../../report.pdf",
            fileExists: { existing.contains($0.path) }
        )

        XCTAssertEqual(destination, directory.appendingPathComponent("report-2.pdf"))
    }

    func testDownloadDestinationReplacesUnsafeOrEmptyNames() {
        XCTAssertEqual(ViewerWebView.DownloadDestination.safeFilename("..\\..\\payload.app"), "payload.app")
        XCTAssertEqual(ViewerWebView.DownloadDestination.safeFilename("../"), "download")
        XCTAssertEqual(ViewerWebView.DownloadDestination.safeFilename("\u{0}"), "download")
    }

    func testFindRequestBuildsNativeConfiguration() {
        let request = ViewerWebView.FindRequest(
            query: "needle",
            sequence: 4,
            backwards: true,
            caseSensitive: true,
            wraps: false
        )

        let configuration = request.configuration
        XCTAssertTrue(configuration.backwards)
        XCTAssertTrue(configuration.caseSensitive)
        XCTAssertFalse(configuration.wraps)
    }

    func testMacOS14CapabilitiesOnlyClaimPublicWebKitControls() {
        let capabilities = ViewerWebView.Capabilities.macOS14

        XCTAssertTrue(capabilities.downloads)
        XCTAssertTrue(capabilities.findInPage)
        XCTAssertTrue(capabilities.nativeContextMenus)
        XCTAssertTrue(capabilities.elementFullscreen)
        XCTAssertFalse(capabilities.pageAudioMute)
        XCTAssertFalse(capabilities.pointerLockControl)
        XCTAssertFalse(capabilities.cursorControl)
    }

    func testNativePerformanceScriptEmitsNativeInputToPresentReceipts() {
        let configuration = NativePerformanceConfiguration(
            outputURL: URL(fileURLWithPath: "/tmp/native-receipt.json"),
            sourceSHA: String(repeating: "a", count: 40),
            runID: "native-test-run",
            expectedCodec: "vp8",
            password: "secret",
            displayName: "Native probe"
        )

        let script = configuration.userScript
        XCTAssertTrue(script.contains("native_input_to_present_receipts"))
        XCTAssertTrue(script.contains("wkwebview-video-frame-callback"))
        XCTAssertFalse(script.contains(#"addEventListener("keydown""#))
        XCTAssertTrue(script.contains("requestVideoFrameCallback"))
        XCTAssertTrue(script.contains("getImageData"))
    }
}
