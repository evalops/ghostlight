import Foundation
import WebKit
import XCTest
@testable import GhostlightApp

final class ViewerWebViewTests: XCTestCase {
    func testViewerLoginScriptInjectsCredentialsOnceAndEscapesJSON() {
        let script = ViewerWebView.viewerLoginScript(
            username: "viewer\"name",
            password: "secret\\value"
        )

        XCTAssertTrue(script.contains(#"sessionStorage.getItem("ghostlight.viewer.authenticated") === "1""#))
        XCTAssertTrue(script.contains(#"fetch("/api/login""#))
        XCTAssertTrue(script.contains(#"sessionStorage.setItem("ghostlight.viewer.authenticated", "1")"#))
        XCTAssertTrue(script.contains(#""username":"viewer\"name""#))
        XCTAssertTrue(script.contains(#""password":"secret\\value""#))
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
}
