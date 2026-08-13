import Foundation
import WebKit

struct NativePerformanceConfiguration: Equatable {
    static let messageHandlerName = "ghostlightPerformance"

    let outputURL: URL
    let sourceSHA: String
    let runID: String
    let expectedCodec: String
    let password: String
    let displayName: String

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> NativePerformanceConfiguration? {
        guard let outputPath = environment["GHOSTLIGHT_NATIVE_PERFORMANCE_OUTPUT"],
              !outputPath.isEmpty,
              let password = environment["GHOSTLIGHT_NATIVE_PERFORMANCE_NEKO_PASSWORD"],
              !password.isEmpty,
              let sourceSHA = environment["GHOSTLIGHT_NATIVE_PERFORMANCE_SOURCE_SHA"],
              sourceSHA.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let runID = environment["GHOSTLIGHT_NATIVE_PERFORMANCE_RUN_ID"],
              !runID.isEmpty,
              let expectedCodec = environment["GHOSTLIGHT_NATIVE_PERFORMANCE_EXPECTED_CODEC"]?.lowercased(),
              ["vp8", "h264"].contains(expectedCodec) else {
            return nil
        }
        return NativePerformanceConfiguration(
            outputURL: URL(fileURLWithPath: outputPath),
            sourceSHA: sourceSHA,
            runID: runID,
            expectedCodec: expectedCodec,
            password: password,
            displayName: environment["GHOSTLIGHT_NATIVE_PERFORMANCE_DISPLAY_NAME"] ?? "Ghostlight Native Performance"
        )
    }

    var userScript: String {
        let passwordLiteral = Self.javascriptLiteral(password)
        let displayNameLiteral = Self.javascriptLiteral(displayName)
        let handler = Self.messageHandlerName
        return #"""
        (() => {
          const peers = [];
          const NativePeerConnection = window.RTCPeerConnection;
          if (NativePeerConnection) {
            const TrackedPeerConnection = function (...args) {
              const peer = new NativePeerConnection(...args);
              peers.push(peer);
              return peer;
            };
            TrackedPeerConnection.prototype = NativePeerConnection.prototype;
            Object.setPrototypeOf(TrackedPeerConnection, NativePeerConnection);
            try {
              Object.defineProperty(window, "RTCPeerConnection", { configurable: true, value: TrackedPeerConnection, writable: true });
            } catch {
              window.RTCPeerConnection = TrackedPeerConnection;
            }
          }

          const setInput = (input, value) => {
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
            if (setter) setter.call(input, value); else input.value = value;
            input.dispatchEvent(new Event("input", { bubbles: true }));
            input.dispatchEvent(new Event("change", { bubbles: true }));
          };
          const connect = () => {
            const inputs = [...document.querySelectorAll("input")];
            const display = inputs.find((entry) => /display name/i.test(entry.placeholder || ""));
            const password = inputs.find((entry) => /password/i.test(entry.placeholder || ""));
            const button = [...document.querySelectorAll("button")].find((entry) => /connect/i.test(entry.textContent || ""));
            if (!display || !password || !button) return false;
            setInput(display, \#(displayNameLiteral));
            setInput(password, \#(passwordLiteral));
            button.click();
            return true;
          };

          let frameCallbacks = 0;
          let nativeInputToPresentReceipts = [];
          let nativeInputSequence = 0;
          let markerWasActive = false;
          const markerCanvas = document.createElement("canvas");
          markerCanvas.width = 1;
          markerCanvas.height = 1;
          const markerContext = markerCanvas.getContext("2d", { willReadFrequently: true });
          const markerIsActive = (video) => {
            if (!video.videoWidth || !video.videoHeight) return false;
            try {
              markerContext.drawImage(video, 80, 70, 8, 8, 0, 0, 1, 1);
              const [red, green, blue] = markerContext.getImageData(0, 0, 1, 1).data;
              return green > 180 && red < 100 && blue < 180;
            } catch {
              return false;
            }
          };
          const observeVideo = () => {
            const video = document.querySelector("video");
            if (!video || video.__ghostlightPerformanceObserved) return;
            video.__ghostlightPerformanceObserved = true;
            const callback = (presentedAt, metadata) => {
              frameCallbacks += 1;
              const markerActive = markerIsActive(video);
              if (markerActive && !markerWasActive) {
                nativeInputSequence += 1;
                nativeInputToPresentReceipts.push({
                  success: true,
                  sequence: nativeInputSequence,
                  observer: "wkwebview-video-frame-callback",
                  presented_at: new Date().toISOString(),
                  media_time_seconds: metadata?.mediaTime ?? null,
                  presented_frames: metadata?.presentedFrames ?? null,
                });
                if (nativeInputToPresentReceipts.length > 100) nativeInputToPresentReceipts.shift();
              }
              markerWasActive = markerActive;
              if ("requestVideoFrameCallback" in video) video.requestVideoFrameCallback(callback);
            };
            if ("requestVideoFrameCallback" in video) video.requestVideoFrameCallback(callback);
          };

          const snapshot = async () => {
            const reports = [];
            for (const peer of peers) {
              try {
                const stats = await peer.getStats();
                stats.forEach((entry) => reports.push({ ...entry }));
              } catch {}
            }
            const inbound = reports.filter((entry) => entry.type === "inbound-rtp" && (entry.kind === "video" || entry.mediaType === "video"));
            const codecs = new Map(reports.filter((entry) => entry.type === "codec").map((entry) => [entry.id, entry]));
            const codecIDs = inbound.map((entry) => entry.codecId).filter(Boolean);
            const codec = codecIDs.map((id) => codecs.get(id)).find(Boolean) || null;
            const sums = inbound.reduce((result, entry) => ({
              bytesReceived: result.bytesReceived + (entry.bytesReceived || 0),
              framesDecoded: result.framesDecoded + (entry.framesDecoded || 0),
              framesDropped: result.framesDropped + (entry.framesDropped || 0),
              totalDecodeTime: result.totalDecodeTime + (entry.totalDecodeTime || 0),
              freezeCount: result.freezeCount + (entry.freezeCount || 0),
              totalFreezesDuration: result.totalFreezesDuration + (entry.totalFreezesDuration || 0),
              framesPerSecond: Math.max(result.framesPerSecond, entry.framesPerSecond || 0),
              frameWidth: Math.max(result.frameWidth, entry.frameWidth || 0),
              frameHeight: Math.max(result.frameHeight, entry.frameHeight || 0),
              powerEfficientDecoder: result.powerEfficientDecoder || entry.powerEfficientDecoder === true,
              hasPowerEfficientDecoder: result.hasPowerEfficientDecoder || typeof entry.powerEfficientDecoder === "boolean",
              decoderImplementation: result.decoderImplementation || entry.decoderImplementation || null,
            }), { bytesReceived: 0, framesDecoded: 0, framesDropped: 0, totalDecodeTime: 0, freezeCount: 0, totalFreezesDuration: 0, framesPerSecond: 0, frameWidth: 0, frameHeight: 0, powerEfficientDecoder: false, hasPowerEfficientDecoder: false, decoderImplementation: null });
            window.webkit.messageHandlers.\#(handler).postMessage({
              captured_at: new Date().toISOString(),
              peer_count: peers.length,
              inbound_count: inbound.length,
              active_media: inbound.length > 0 && sums.framesDecoded > 0 ? 1 : 0,
              bytes_received: sums.bytesReceived,
              frames_decoded: sums.framesDecoded,
              frames_dropped: sums.framesDropped,
              total_decode_time_seconds: sums.totalDecodeTime,
              freeze_count: sums.freezeCount,
              total_freezes_duration_seconds: sums.totalFreezesDuration,
              mean_decode_ms: sums.framesDecoded > 0 ? sums.totalDecodeTime * 1000 / sums.framesDecoded : null,
              frames_per_second: sums.framesPerSecond || null,
              frame_width: sums.frameWidth || null,
              frame_height: sums.frameHeight || null,
              power_efficient_decoder: sums.hasPowerEfficientDecoder ? sums.powerEfficientDecoder : null,
              decoder_implementation: sums.decoderImplementation,
              frame_callbacks: frameCallbacks,
              native_input_to_present_receipts: nativeInputToPresentReceipts.slice(),
              codec: codec ? { mime_type: codec.mimeType || null, sdp_fmtp_line: codec.sdpFmtpLine || null } : null,
            });
          };

          const timer = setInterval(() => {
            observeVideo();
            // Neko renders its video element before authentication. Presence of
            // that element therefore cannot prove that the observer connected.
            if (peers.length === 0) connect();
            snapshot().catch(() => {});
          }, 1000);
          window.addEventListener("pagehide", () => clearInterval(timer), { once: true });
        })();
        """#
    }

    private static func javascriptLiteral(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

final class NativePerformanceRecorder: NSObject, WKScriptMessageHandler {
    private let configuration: NativePerformanceConfiguration
    private var samples: [Any] = []
    private var nativeInputToPresentReceipts: [Any] = []

    init(configuration: NativePerformanceConfiguration) {
        self.configuration = configuration
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == NativePerformanceConfiguration.messageHandlerName,
              JSONSerialization.isValidJSONObject(message.body) else {
            return
        }
        samples.append(message.body)
        if let sample = message.body as? [String: Any],
           let receipts = sample["native_input_to_present_receipts"] as? [Any] {
            nativeInputToPresentReceipts = Array(receipts.suffix(100))
        }
        if samples.count > 360 {
            samples.removeFirst(samples.count - 360)
        }
        let envelope: [String: Any] = [
            "schema_version": 1,
            "source_sha": configuration.sourceSHA,
            "run_id": configuration.runID,
            "expected_codec": configuration.expectedCodec,
            "observer": "Ghostlight.app WKWebView",
            "native_input_to_present_receipts": nativeInputToPresentReceipts,
            "samples": samples,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            let directory = configuration.outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: configuration.outputURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.outputURL.path)
        } catch {
            fputs("Ghostlight native performance receipt write failed: \(error.localizedDescription)\n", stderr)
        }
    }
}
