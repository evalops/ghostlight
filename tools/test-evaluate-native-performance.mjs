import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "ghostlight-native-performance-"));
const sourceSHA = "a".repeat(40);
const phaseNames = ["static-gmail", "scrolling", "typing", "animation"];

try {
  const samples = [];
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
    }));
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
      });
      cpuRows.push(`${capturedAt}\t100\t1\t8\t102400\tapp\tGhostlightApp`);
    }
  }
  const rawPath = path.join(temporary, "raw.json");
  const cpuPath = path.join(temporary, "cpu.tsv");
  const outputPath = path.join(temporary, "receipt.json");
  fs.writeFileSync(rawPath, JSON.stringify({ source_sha: sourceSHA, expected_codec: "h264", observer: "test", samples }));
  fs.writeFileSync(cpuPath, `${cpuRows.join("\n")}\n`);

  const evaluate = () => spawnSync(process.execPath, [
    path.join(root, "tools/evaluate-native-performance.mjs"),
    rawPath, cpuPath, "h264", sourceSHA, outputPath, temporary,
  ], { encoding: "utf8" });
  const measured = evaluate();
  assert.equal(measured.status, 0, measured.stderr || measured.stdout);
  const receipt = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(receipt.status, "measured");
  assert.equal(receipt.full_phase_coverage, 1);
  assert.equal(receipt.phases.length, 4);
  assert.equal(receipt.power_efficient_decoder, null);
  assert.equal(receipt.mac_cpu_median_pct, 8);

  fs.writeFileSync(cpuPath, `${cpuRows.filter((row) => !row.startsWith("2026-08-13T00:01:0")).join("\n")}\n`);
  const blocked = evaluate();
  assert.notEqual(blocked.status, 0);
  assert.equal(JSON.parse(fs.readFileSync(outputPath, "utf8")).full_phase_coverage, 0);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
