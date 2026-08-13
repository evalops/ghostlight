import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "ghostlight-codec-pair-"));
const sourceSHA = "a".repeat(40);
const imageReference = `example.invalid/viewer@sha256:${"b".repeat(64)}`;
const order = [
  ["pair-1/vp8", "vp8"], ["pair-1/h264", "h264"],
  ["pair-2/h264", "h264"], ["pair-2/vp8", "vp8"],
  ["pair-3/vp8", "vp8"], ["pair-3/h264", "h264"],
];

try {
  for (const [directory, codec] of order) {
    const runDirectory = path.join(temporary, directory);
    const nativeDirectory = path.join(runDirectory, "native");
    fs.mkdirSync(nativeDirectory, { recursive: true });
    const mimeType = `video/${codec.toUpperCase()}`;
    const server = {
      status: "measured",
      error: null,
      source: { sourceSha: sourceSHA },
      image: { reference: imageReference },
      configuration: { codec },
      viewer_cpu_median_pct: codec === "vp8" ? 100 : 80,
      diagnostics: {
        active_media: 1,
        actual_to_target_fps_ratio: 1,
        dropped_frame_ratio: 0,
        freeze_ratio: 0,
        visual_event_success_rate: 1,
        input_to_present_p95_ms: codec === "vp8" ? 200 : 180,
        bitrate_bps: 1_000_000,
        viewer_memory_p95_mib: 512,
      },
      phases: Array.from({ length: 4 }, () => ({
        active_media: 1,
        actual_to_target_fps_ratio: 1,
        dropped_frame_ratio: 0,
        freeze_stats_available: true,
        freeze_events: 0,
        freeze_ratio: 0,
        visual_event_success_rate: 1,
        input_to_present_p95_ms: codec === "vp8" ? 200 : 180,
        codec: { mime_type: mimeType },
        selected_ice_pair: { protocol: "udp" },
      })),
    };
    const native = {
      status: "measured",
      source_sha: sourceSHA,
      expected_codec: codec,
      codec: { mime_type: mimeType },
      active_media: 1,
      power_efficient_decoder: null,
      mac_cpu_median_pct: codec === "vp8" ? 10 : 8,
      mean_decode_ms: 2,
      full_phase_coverage: 1,
      phases: Array.from({ length: 4 }, () => ({ media_sample_count: 20, process_sample_count: 20 })),
    };
    fs.writeFileSync(path.join(runDirectory, "receipt.json"), JSON.stringify(server));
    fs.writeFileSync(path.join(nativeDirectory, "native-receipt.json"), JSON.stringify(native));
  }

  const output = path.join(temporary, "result.json");
  const evaluation = spawnSync(
    process.execPath,
    [path.join(root, "tools/evaluate-codec-pair.mjs"), temporary, output],
    { encoding: "utf8" },
  );
  assert.equal(evaluation.status, 0, evaluation.stderr || evaluation.stdout);
  const result = JSON.parse(fs.readFileSync(output, "utf8"));
  assert.equal(result.negotiated_codec_pair, 1);
  assert.equal(result.gates.negotiated_codec_pair, true);
  assert.equal(result.native_h264_power_efficient_decoder, 0);
  assert.equal(result.status, "accepted");

  const brokenPath = path.join(temporary, "pair-1/vp8/receipt.json");
  const broken = JSON.parse(fs.readFileSync(brokenPath, "utf8"));
  broken.phases[0].freeze_stats_available = false;
  fs.writeFileSync(brokenPath, JSON.stringify(broken));
  const rejected = spawnSync(
    process.execPath,
    [path.join(root, "tools/evaluate-codec-pair.mjs"), temporary, output],
    { encoding: "utf8" },
  );
  assert.notEqual(rejected.status, 0);
  assert.equal(JSON.parse(fs.readFileSync(output, "utf8")).gates.absolute_control_health, false);

  broken.phases[0].freeze_stats_available = true;
  fs.writeFileSync(brokenPath, JSON.stringify(broken));
  const nativePath = path.join(temporary, "pair-1/h264/native/native-receipt.json");
  const native = JSON.parse(fs.readFileSync(nativePath, "utf8"));
  native.mac_cpu_median_pct = null;
  fs.writeFileSync(nativePath, JSON.stringify(native));
  const missingNativeCPU = spawnSync(
    process.execPath,
    [path.join(root, "tools/evaluate-codec-pair.mjs"), temporary, output],
    { encoding: "utf8" },
  );
  assert.notEqual(missingNativeCPU.status, 0);
  assert.equal(JSON.parse(fs.readFileSync(output, "utf8")).gates.native_mac_cpu_ratio, false);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
