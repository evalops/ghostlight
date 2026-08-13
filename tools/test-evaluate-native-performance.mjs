import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "ghostlight-native-performance-"));
const sourceSHA = "a".repeat(40);
const runID = "native-test-run";
const phaseNames = ["static-gmail", "scrolling", "typing", "animation"];

try {
  fs.writeFileSync(path.join(temporary, "run-config.json"), JSON.stringify({ run_id: runID }));
  const samples = [];
  const causalMarkerReceipts = [];
  const cpuRows = [];
  let frames = 0;
  let bytes = 0;
  let decodeSeconds = 0;
  for (const [phaseIndex, phase] of phaseNames.entries()) {
    const start = Date.parse("2026-08-13T00:00:00.000Z") + phaseIndex * 20_000;
    fs.writeFileSync(path.join(temporary, `phase-${phase}.json`), JSON.stringify({
      phase,
      phase_start: new Date(start).toISOString(),
      phase_end: new Date(start + 9_000).toISOString(),
      active_media: 1,
      decoded_frames: 225,
      dropped_frames: 0,
      dropped_frame_ratio: 0,
      codec: { mime_type: "video/H264" },
      selected_ice_pair: { protocol: "udp" },
      visual_event_attempts: 3,
      visual_event_successes: 3,
      visual_event_success_rate: 1,
      input_to_present_receipts: Array.from({ length: 3 }, (_, index) => ({
        success: true,
        input_at: new Date(start + (index + 1) * 2_000 - 100).toISOString(),
        input_to_present_ms: 100 + index,
        input_driver: "x11-xdotool-persistent-ssh",
      })),
      frame_sample_count: 225,
      frame_width: 1920,
      frame_height: 1080,
    }));
    for (let marker = 0; marker < 3; marker += 1) {
      causalMarkerReceipts.push({
        sequence: phaseIndex * 3 + marker + 1,
        success: true,
        observer: "wkwebview-video-frame-callback",
        presented_at: new Date(start + (marker + 1) * 2_000).toISOString(),
      });
    }
    for (let second = 0; second < 10; second += 1) {
      frames += 25;
      bytes += 100_000;
      decodeSeconds += 0.05;
      const capturedAt = new Date(start + second * 1_000).toISOString();
      samples.push({
        captured_at: capturedAt,
        active_media: 1,
        frames_decoded: frames,
        frames_dropped: 0,
        bytes_received: bytes,
        total_decode_time_seconds: decodeSeconds,
        freeze_count: 0,
        total_freezes_duration_seconds: 0,
        codec: { mime_type: "video/H264" },
        power_efficient_decoder: null,
        native_input_to_present_receipts: causalMarkerReceipts.filter((entry) => Date.parse(entry.presented_at) <= Date.parse(capturedAt)),
      });
      cpuRows.push(`${capturedAt}\t100\t1\t8\t102400\tapp\t100\tGhostlightApp`);
      cpuRows.push(`${capturedAt}\t200\t100\t4\t204800\tapp-owned-webkit-process\t100\tcom.apple.WebKit.WebContent`);
    }
  }
  const rawPath = path.join(temporary, "raw.json");
  const cpuPath = path.join(temporary, "cpu.tsv");
  const outputPath = path.join(temporary, "receipt.json");
  const validRaw = {
    schema_version: 2,
    source_sha: sourceSHA,
    run_id: runID,
    expected_codec: "h264",
    observer: "Ghostlight.app WKWebView",
    samples,
  };
  fs.writeFileSync(rawPath, JSON.stringify(validRaw));
  fs.writeFileSync(cpuPath, `${cpuRows.join("\n")}\n`);

  const evaluate = () => spawnSync(process.execPath, [
    path.join(root, "tools/evaluate-native-performance.mjs"),
    rawPath, cpuPath, "h264", sourceSHA, outputPath, temporary,
  ], { encoding: "utf8" });
  const measured = evaluate();
  assert.equal(measured.status, 0, measured.stderr || measured.stdout);
  const receipt = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(receipt.status, "observed");
  assert.equal(receipt.full_phase_coverage, 1);
  assert.equal(receipt.phases.length, 4);
  assert.equal(receipt.power_efficient_decoder, null);
  assert.equal(receipt.mac_cpu_median_pct, 12);
  assert.equal(receipt.evidence.exact_source, true);
  assert.equal(receipt.evidence.direct_selected_udp, true);
  assert.equal(receipt.evidence.causal_wkwebview_native_marker, true);
  assert.equal(receipt.evidence.webrtc_dropped_frames, true);
  assert.equal(receipt.evidence.process_cpu_memory, true);

  const phasePath = path.join(temporary, "phase-static-gmail.json");
  const validPhase = JSON.parse(fs.readFileSync(phasePath, "utf8"));
  const assertBlocked = (mutate, pattern) => {
    mutate();
    const result = evaluate();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr || result.stdout, pattern);
    fs.writeFileSync(phasePath, JSON.stringify(validPhase));
  };
  assertBlocked(() => fs.writeFileSync(phasePath, JSON.stringify({ ...validPhase, selected_ice_pair: { protocol: "tcp" } })), /selected UDP/i);
  assertBlocked(() => fs.writeFileSync(rawPath, JSON.stringify({
    ...validRaw,
    samples: validRaw.samples.map((sample) => ({ ...sample, native_input_to_present_receipts: [] })),
  })), /WKWebView-native causal marker/i);
  fs.writeFileSync(rawPath, JSON.stringify(validRaw));
  assertBlocked(() => fs.writeFileSync(rawPath, JSON.stringify({
    ...validRaw,
    samples: validRaw.samples.map(({ native_input_to_present_receipts: _ignored, ...sample }) => sample),
    causal_marker_source: "playwright-phase-receipt",
    causal_marker_receipts: causalMarkerReceipts,
  })), /WKWebView-native causal marker/i);
  fs.writeFileSync(rawPath, JSON.stringify(validRaw));
  assertBlocked(() => fs.writeFileSync(rawPath, JSON.stringify({ ...validRaw, observer: "test" })), /WKWebView-native observer provenance/i);
  fs.writeFileSync(rawPath, JSON.stringify(validRaw));
  assertBlocked(() => {
    const missingDrops = { ...validPhase };
    delete missingDrops.dropped_frames;
    fs.writeFileSync(phasePath, JSON.stringify(missingDrops));
  }, /WebRTC dropped-frame/i);
  fs.writeFileSync(cpuPath, `${cpuRows.filter((row) => !row.startsWith("2026-08-13T00:01:0")).join("\n")}\n`);
  const blocked = evaluate();
  assert.notEqual(blocked.status, 0);
  assert.equal(JSON.parse(fs.readFileSync(outputPath, "utf8")).full_phase_coverage, 0);

  fs.writeFileSync(cpuPath, `${cpuRows.map((row) => row.includes("app-owned-webkit-process")
    ? row.replace("app-owned-webkit-process\t100", "new-webkit-process\t")
    : row).join("\n")}\n`);
  const missingWebKit = evaluate();
  assert.notEqual(missingWebKit.status, 0);
  assert.equal(JSON.parse(fs.readFileSync(outputPath, "utf8")).evidence.process_cpu_memory, false);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
