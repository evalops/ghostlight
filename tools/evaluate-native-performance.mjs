import fs from "node:fs";

const [rawPath, cpuPath, expectedCodec, sourceSha, outputPath, phaseDirectory] = process.argv.slice(2);
if (!rawPath || !cpuPath || !expectedCodec || !sourceSha || !outputPath || !phaseDirectory) {
  throw new Error("usage: evaluate-native-performance.mjs <raw-json> <cpu-tsv> <vp8|h264> <source-sha> <output-json> <phase-directory>");
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
const last = active.at(-1) ?? null;
const mimeType = last?.codec?.mime_type?.toLowerCase() ?? null;
const codecMatches = expectedCodec === "vp8" ? mimeType === "video/vp8" : mimeType === "video/h264";
const phaseNames = ["static-gmail", "scrolling", "typing", "animation"];
const phaseWindows = phaseNames.map((phase) => {
  const receipt = JSON.parse(fs.readFileSync(`${phaseDirectory}/phase-${phase}.json`, "utf8"));
  if (receipt.phase !== phase || !receipt.phase_start || !receipt.phase_end) throw new Error(`invalid native phase window for ${phase}`);
  return { phase, start: Date.parse(receipt.phase_start), end: Date.parse(receipt.phase_end) };
});
const inWindow = (capturedAt, window) => {
  const timestamp = Date.parse(capturedAt);
  return Number.isFinite(timestamp) && timestamp >= window.start && timestamp <= window.end;
};

const cpuRows = fs.readFileSync(cpuPath, "utf8").trim().split("\n").filter(Boolean).map((line) => {
  const [capturedAt, pid, ppid, cpuPct, rssKiB, lineage, ...command] = line.split("\t");
  return { capturedAt, pid: Number(pid), ppid: Number(ppid), cpuPct: Number(cpuPct), rssKiB: Number(rssKiB), lineage, command: command.join("\t") };
});
const summarizeProcessRows = (rows) => {
  const byTimestamp = new Map();
  for (const row of rows) {
    const summary = byTimestamp.get(row.capturedAt) ?? { cpu: 0, rssKiB: 0 };
    summary.cpu += row.cpuPct;
    summary.rssKiB += row.rssKiB;
    byTimestamp.set(row.capturedAt, summary);
  }
  return [...byTimestamp.entries()]
    .map(([capturedAt, entry]) => ({ captured_at: capturedAt, cpu_pct: entry.cpu, memory_mib: entry.rssKiB / 1024 }))
    .filter((sample) => Number.isFinite(Date.parse(sample.captured_at)) && Number.isFinite(sample.cpu_pct) && Number.isFinite(sample.memory_mib));
};
const delta = (first, final, field) => first && final ? Math.max(0, (final[field] ?? 0) - (first[field] ?? 0)) : 0;
const phases = phaseWindows.map((window) => {
  const mediaSamples = active.filter((sample) => inWindow(sample.captured_at, window));
  const processSamples = summarizeProcessRows(cpuRows.filter((row) => inWindow(row.capturedAt, window)));
  const first = mediaSamples[0] ?? null;
  const final = mediaSamples.at(-1) ?? null;
  const elapsedSeconds = first && final ? (Date.parse(final.captured_at) - Date.parse(first.captured_at)) / 1000 : 0;
  const decodedFrames = delta(first, final, "frames_decoded");
  const droppedFrames = delta(first, final, "frames_dropped");
  const receivedBytes = delta(first, final, "bytes_received");
  const decodeSeconds = delta(first, final, "total_decode_time_seconds");
  return {
    phase: window.phase,
    phase_start: new Date(window.start).toISOString(),
    phase_end: new Date(window.end).toISOString(),
    media_sample_count: mediaSamples.length,
    process_sample_count: processSamples.length,
    elapsed_seconds: elapsedSeconds,
    decoded_frames: decodedFrames,
    dropped_frames: droppedFrames,
    dropped_frame_ratio: ratio(droppedFrames, decodedFrames + droppedFrames),
    decoded_fps: ratio(decodedFrames, elapsedSeconds),
    bitrate_bps: ratio(receivedBytes * 8, elapsedSeconds),
    mean_decode_ms: ratio(decodeSeconds * 1000, decodedFrames),
    freeze_count: delta(first, final, "freeze_count"),
    total_freezes_duration_seconds: delta(first, final, "total_freezes_duration_seconds"),
    mac_cpu_median_pct: median(processSamples.map((sample) => sample.cpu_pct)),
    mac_memory_median_mib: median(processSamples.map((sample) => sample.memory_mib)),
    process_samples: processSamples,
  };
});
const cpuSamples = phases.flatMap((phase) => phase.process_samples.map((sample) => sample.cpu_pct));
const memorySamples = phases.flatMap((phase) => phase.process_samples.map((sample) => sample.memory_mib));
const decodedFrames = phases.reduce((sum, phase) => sum + phase.decoded_frames, 0);
const droppedFrames = phases.reduce((sum, phase) => sum + phase.dropped_frames, 0);
const elapsedSeconds = phases.reduce((sum, phase) => sum + phase.elapsed_seconds, 0);
const receivedBits = phases.reduce((sum, phase) => sum + (phase.bitrate_bps ?? 0) * phase.elapsed_seconds, 0);
const decodeMilliseconds = phases.reduce((sum, phase) => sum + (phase.mean_decode_ms ?? 0) * phase.decoded_frames, 0);
const fullPhaseCoverage = phases.every((phase) => phase.media_sample_count >= 5
  && phase.process_sample_count >= 5
  && phase.decoded_frames > 0
  && Number.isFinite(phase.mac_cpu_median_pct)
  && Number.isFinite(phase.mac_memory_median_mib));
const observedProcesses = [...new Map(cpuRows.map((row) => [row.pid, { pid: row.pid, ppid: row.ppid, lineage: row.lineage, command: row.command }])).values()];

const receipt = {
  schema_version: 2,
  status: fullPhaseCoverage && decodedFrames > 0 && codecMatches ? "measured" : "blocked",
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
  bitrate_bps: ratio(receivedBits, elapsedSeconds),
  mean_decode_ms: ratio(decodeMilliseconds, decodedFrames),
  power_efficient_decoder: last?.power_efficient_decoder ?? null,
  decoder_implementation: last?.decoder_implementation ?? null,
  frame_width: last?.frame_width ?? null,
  frame_height: last?.frame_height ?? null,
  frame_callbacks: last?.frame_callbacks ?? null,
  mac_cpu_median_pct: median(cpuSamples),
  mac_memory_median_mib: median(memorySamples),
  process_sample_count: cpuSamples.length,
  full_phase_coverage: fullPhaseCoverage ? 1 : 0,
  phases,
  process_selection: "GhostlightApp PID plus WebKit processes absent from the pre-launch baseline; no unrelated existing WebKit process is included.",
  observed_processes: observedProcesses,
  raw_samples: raw.samples,
};
if (receipt.status !== "measured") receipt.error = "native receipt requires intended codec plus at least five active media and WebKit process-family samples with decoded frames in every phase";
fs.writeFileSync(outputPath, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
console.log(JSON.stringify(receipt));
if (receipt.status !== "measured") process.exitCode = 1;
