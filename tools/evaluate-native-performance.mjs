import fs from "node:fs";

const [rawPath, cpuPath, expectedCodec, sourceSha, outputPath] = process.argv.slice(2);
if (!rawPath || !cpuPath || !expectedCodec || !sourceSha || !outputPath) {
  throw new Error("usage: evaluate-native-performance.mjs <raw-json> <cpu-tsv> <vp8|h264> <source-sha> <output-json>");
}

const median = (values) => {
  const sorted = values.filter(Number.isFinite).toSorted((left, right) => left - right);
  if (!sorted.length) return null;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
const ratio = (numerator, denominator) => Number.isFinite(numerator) && denominator > 0 ? numerator / denominator : null;
const raw = JSON.parse(fs.readFileSync(rawPath, "utf8"));
if (raw.source_sha !== sourceSha || raw.expected_codec !== expectedCodec) throw new Error("native raw receipt provenance mismatch");
const active = raw.samples.filter((sample) => sample.active_media === 1 && sample.frames_decoded > 0);
const first = active[0] ?? null;
const last = active.at(-1) ?? null;
const elapsedSeconds = first && last ? (Date.parse(last.captured_at) - Date.parse(first.captured_at)) / 1000 : 0;
const decodedFrames = first && last ? last.frames_decoded - first.frames_decoded : 0;
const droppedFrames = first && last ? last.frames_dropped - first.frames_dropped : 0;
const receivedBytes = first && last ? last.bytes_received - first.bytes_received : 0;
const decodeSeconds = first && last ? last.total_decode_time_seconds - first.total_decode_time_seconds : 0;
const mimeType = last?.codec?.mime_type?.toLowerCase() ?? null;
const codecMatches = expectedCodec === "vp8" ? mimeType === "video/vp8" : mimeType === "video/h264";

const cpuRows = fs.readFileSync(cpuPath, "utf8").trim().split("\n").filter(Boolean).map((line) => {
  const [capturedAt, pid, ppid, cpuPct, rssKiB, lineage, ...command] = line.split("\t");
  return { capturedAt, pid: Number(pid), ppid: Number(ppid), cpuPct: Number(cpuPct), rssKiB: Number(rssKiB), lineage, command: command.join("\t") };
});
const byTimestamp = new Map();
for (const row of cpuRows) {
  const summary = byTimestamp.get(row.capturedAt) ?? { cpu: 0, rssKiB: 0 };
  summary.cpu += row.cpuPct;
  summary.rssKiB += row.rssKiB;
  byTimestamp.set(row.capturedAt, summary);
}
const cpuSamples = [...byTimestamp.values()].map((entry) => entry.cpu);
const memorySamples = [...byTimestamp.values()].map((entry) => entry.rssKiB / 1024);
const observedProcesses = [...new Map(cpuRows.map((row) => [row.pid, { pid: row.pid, ppid: row.ppid, lineage: row.lineage, command: row.command }])).values()];

const receipt = {
  schema_version: 1,
  status: active.length >= 5 && decodedFrames > 0 && codecMatches && cpuSamples.length >= 5 ? "measured" : "blocked",
  source_sha: sourceSha,
  observer: raw.observer,
  expected_codec: expectedCodec,
  codec: last?.codec ?? null,
  codec_matches: codecMatches,
  active_media: decodedFrames > 0 ? 1 : 0,
  sample_count: active.length,
  elapsed_seconds: elapsedSeconds,
  decoded_frames: decodedFrames,
  dropped_frames: droppedFrames,
  dropped_frame_ratio: ratio(droppedFrames, decodedFrames + droppedFrames),
  decoded_fps: ratio(decodedFrames, elapsedSeconds),
  bitrate_bps: ratio(receivedBytes * 8, elapsedSeconds),
  mean_decode_ms: ratio(decodeSeconds * 1000, decodedFrames),
  power_efficient_decoder: last?.power_efficient_decoder ?? null,
  frame_width: last?.frame_width ?? null,
  frame_height: last?.frame_height ?? null,
  frame_callbacks: last?.frame_callbacks ?? null,
  mac_cpu_median_pct: median(cpuSamples),
  mac_memory_median_mib: median(memorySamples),
  process_sample_count: cpuSamples.length,
  process_selection: "GhostlightApp PID plus WebKit processes absent from the pre-launch baseline; no unrelated existing WebKit process is included.",
  observed_processes: observedProcesses,
  raw_samples: raw.samples,
};
if (receipt.status !== "measured") receipt.error = "native receipt requires active decoded media, intended codec, and at least five WebKit process-family CPU samples";
fs.writeFileSync(outputPath, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
console.log(JSON.stringify(receipt));
if (receipt.status !== "measured") process.exitCode = 1;
