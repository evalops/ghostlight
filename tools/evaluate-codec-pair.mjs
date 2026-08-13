import fs from "node:fs";
import path from "node:path";

const [pairRoot, outputPath] = process.argv.slice(2);
if (!pairRoot || !outputPath) throw new Error("usage: evaluate-codec-pair.mjs <pair-root> <output-json>");

const median = (values) => {
  const sorted = values.filter(Number.isFinite).toSorted((left, right) => left - right);
  if (!sorted.length) return null;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
const ratio = (numerator, denominator) => Number.isFinite(numerator) && denominator > 0 ? numerator / denominator : null;
const read = (relative) => JSON.parse(fs.readFileSync(path.join(pairRoot, relative), "utf8"));
const order = [
  ["pair-1/vp8", "vp8"], ["pair-1/h264", "h264"],
  ["pair-2/h264", "h264"], ["pair-2/vp8", "vp8"],
  ["pair-3/vp8", "vp8"], ["pair-3/h264", "h264"],
];
const runs = order.map(([directory, codec]) => ({
  directory,
  codec,
  server: read(`${directory}/receipt.json`),
  native: read(`${directory}/native/native-receipt.json`),
}));
const vp8 = runs.filter((run) => run.codec === "vp8");
const h264 = runs.filter((run) => run.codec === "h264");
const sourceSHAs = new Set(runs.flatMap((run) => [run.server.source?.sourceSha, run.native.source_sha]));
const imageReferences = new Set(runs.map((run) => run.server.image?.reference));
const codecMatches = runs.every((run) => run.server.configuration?.codec === run.codec
  && run.server.phases?.length === 4
  && run.server.phases.every((phase) => phase.codec?.mime_type?.toLowerCase() === `video/${run.codec}`)
  && run.native.expected_codec === run.codec
  && run.native.codec?.mime_type?.toLowerCase() === `video/${run.codec}`);
const selectedUDP = runs.every((run) => run.server.phases?.length === 4
  && run.server.phases.every((phase) => phase.selected_ice_pair?.protocol?.toLowerCase() === "udp"));
const healthyPhase = (phase) => phase.active_media === 1
  && phase.actual_to_target_fps_ratio >= 0.90
  && phase.dropped_frame_ratio <= 0.01
  && phase.freeze_stats_available === true
  && phase.freeze_events === 0
  && phase.freeze_ratio === 0
  && phase.visual_event_success_rate >= 0.99
  && phase.input_to_present_p95_ms <= 1000;
const controlHealthy = vp8.every((run) => run.server.status === "measured"
  && run.server.diagnostics?.active_media === 1
  && run.server.diagnostics?.actual_to_target_fps_ratio >= 0.90
  && run.server.diagnostics?.dropped_frame_ratio <= 0.01
  && run.server.diagnostics?.freeze_ratio === 0
  && run.server.diagnostics?.visual_event_success_rate >= 0.99
  && run.server.diagnostics?.input_to_present_p95_ms <= 1000
  && run.server.phases?.length === 4
  && run.server.phases.every(healthyPhase));
const candidateHealthy = h264.every((run) => run.server.status === "measured"
  && run.server.phases?.length === 4
  && run.server.phases.every(healthyPhase));
const serverMeasured = runs.every((run) => run.server.status === "measured" && run.server.phases?.length === 4 && run.server.error == null);
const nativeMeasured = runs.every((run) => run.native.status === "measured" && run.native.full_phase_coverage === 1 && run.native.phases?.length === 4);

const metric = (group, selector) => median(group.map(selector));
const vp8Cpu = metric(vp8, (run) => run.server.viewer_cpu_median_pct);
const h264Cpu = metric(h264, (run) => run.server.viewer_cpu_median_pct);
const vp8MacCpu = metric(vp8, (run) => run.native.mac_cpu_median_pct);
const h264MacCpu = metric(h264, (run) => run.native.mac_cpu_median_pct);
const pairComparisons = [1, 2, 3].map((pair) => {
  const control = runs.find((run) => run.directory === `pair-${pair}/vp8`);
  const candidate = runs.find((run) => run.directory === `pair-${pair}/h264`);
  return {
    pair,
    viewer_cpu_reduction_pct: control?.server.viewer_cpu_median_pct > 0 ? ((control.server.viewer_cpu_median_pct - candidate.server.viewer_cpu_median_pct) / control.server.viewer_cpu_median_pct) * 100 : null,
    dropped_frame_ratio_delta: Number.isFinite(control?.server.diagnostics?.dropped_frame_ratio) && Number.isFinite(candidate?.server.diagnostics?.dropped_frame_ratio) ? candidate.server.diagnostics.dropped_frame_ratio - control.server.diagnostics.dropped_frame_ratio : null,
    freeze_ratio_delta: Number.isFinite(control?.server.diagnostics?.freeze_ratio) && Number.isFinite(candidate?.server.diagnostics?.freeze_ratio) ? candidate.server.diagnostics.freeze_ratio - control.server.diagnostics.freeze_ratio : null,
    input_p95_control_ratio: ratio(candidate?.server.diagnostics?.input_to_present_p95_ms, control?.server.diagnostics?.input_to_present_p95_ms),
    native_mac_cpu_ratio: ratio(candidate?.native.mac_cpu_median_pct, control?.native.mac_cpu_median_pct),
  };
});
const cpuReduction = median(pairComparisons.map((pair) => pair.viewer_cpu_reduction_pct));
const worstFinite = (values) => values.every(Number.isFinite) ? Math.max(...values) : null;
const result = {
  schema_version: 1,
  captured_at: new Date().toISOString(),
  source_sha: sourceSHAs.size === 1 ? [...sourceSHAs][0] : null,
  image_reference: imageReferences.size === 1 ? [...imageReferences][0] : null,
  run_order: order.map(([directory, codec]) => ({ directory, codec })),
  viewer_cpu_reduction_pct: cpuReduction,
  pair_complete: runs.length === 6 && serverMeasured && nativeMeasured ? 1 : 0,
  exact_source_match: sourceSHAs.size === 1 && !sourceSHAs.has(undefined) ? 1 : 0,
  selected_udp_all_phases: selectedUDP ? 1 : 0,
  negotiated_codec_pair: codecMatches ? 1 : 0,
  causal_marker_success_rate: Math.min(...runs.map((run) => run.server.diagnostics.visual_event_success_rate ?? 0)),
  actual_to_target_fps_ratio: metric(h264, (run) => run.server.diagnostics.actual_to_target_fps_ratio),
  dropped_frame_ratio_delta: worstFinite(pairComparisons.map((pair) => pair.dropped_frame_ratio_delta)),
  freeze_ratio_delta: worstFinite(pairComparisons.map((pair) => pair.freeze_ratio_delta)),
  input_p95_control_ratio: worstFinite(pairComparisons.map((pair) => pair.input_p95_control_ratio)),
  native_h264_active_media: h264.every((run) => run.native.active_media === 1) ? 1 : 0,
  native_h264_power_efficient_decoder: h264.every((run) => run.native.power_efficient_decoder === true) ? 1 : 0,
  native_full_phase_coverage: nativeMeasured ? 1 : 0,
  native_mac_cpu_ratio: worstFinite(pairComparisons.map((pair) => pair.native_mac_cpu_ratio)),
  absolute_control_health: controlHealthy ? 1 : 0,
  absolute_candidate_health: candidateHealthy ? 1 : 0,
  vp8_viewer_cpu_median_pct: vp8Cpu,
  h264_viewer_cpu_median_pct: h264Cpu,
  vp8_mac_cpu_median_pct: vp8MacCpu,
  h264_mac_cpu_median_pct: h264MacCpu,
  vp8_mean_decode_ms: metric(vp8, (run) => run.native.mean_decode_ms),
  h264_mean_decode_ms: metric(h264, (run) => run.native.mean_decode_ms),
  vp8_bitrate_bps: metric(vp8, (run) => run.server.diagnostics.bitrate_bps),
  h264_bitrate_bps: metric(h264, (run) => run.server.diagnostics.bitrate_bps),
  vp8_memory_p95_mib: metric(vp8, (run) => run.server.diagnostics.viewer_memory_p95_mib),
  h264_memory_p95_mib: metric(h264, (run) => run.server.diagnostics.viewer_memory_p95_mib),
  pair_comparisons: pairComparisons,
  runs: runs.map((run) => ({
    directory: run.directory,
    codec: run.codec,
    server_status: run.server.status,
    native_status: run.native.status,
    viewer_cpu_median_pct: run.server.viewer_cpu_median_pct,
    input_p95_ms: run.server.diagnostics?.input_to_present_p95_ms,
    dropped_frame_ratio: run.server.diagnostics?.dropped_frame_ratio,
    freeze_ratio: run.server.diagnostics?.freeze_ratio,
    native_mac_cpu_median_pct: run.native.mac_cpu_median_pct,
    native_power_efficient_decoder: run.native.power_efficient_decoder,
    native_decoder_implementation: run.native.decoder_implementation,
    native_full_phase_coverage: run.native.full_phase_coverage,
  })),
};
const gates = {
  pair_complete: result.pair_complete === 1,
  exact_source_match: result.exact_source_match === 1,
  selected_udp_all_phases: result.selected_udp_all_phases === 1,
  negotiated_codec_pair: result.negotiated_codec_pair === 1,
  absolute_control_health: result.absolute_control_health === 1,
  absolute_candidate_health: result.absolute_candidate_health === 1,
  causal_marker_success_rate: result.causal_marker_success_rate >= 0.99,
  actual_to_target_fps_ratio: result.actual_to_target_fps_ratio >= 0.90,
  dropped_frame_ratio_delta: Number.isFinite(result.dropped_frame_ratio_delta) && result.dropped_frame_ratio_delta <= 0,
  freeze_ratio_delta: Number.isFinite(result.freeze_ratio_delta) && result.freeze_ratio_delta <= 0,
  input_p95_control_ratio: Number.isFinite(result.input_p95_control_ratio) && result.input_p95_control_ratio <= 1,
  viewer_cpu_reduction_pct: Number.isFinite(result.viewer_cpu_reduction_pct) && result.viewer_cpu_reduction_pct >= 5,
  native_h264_active_media: result.native_h264_active_media === 1,
  native_full_phase_coverage: result.native_full_phase_coverage === 1,
  native_mac_cpu_ratio: Number.isFinite(result.native_mac_cpu_ratio) && result.native_mac_cpu_ratio <= 1,
};
result.gates = { ...gates, passed: Object.values(gates).every(Boolean) };
result.status = result.gates.passed ? "accepted" : "rejected";
fs.writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
console.log(JSON.stringify(result));
if (!result.gates.passed) process.exitCode = 1;
