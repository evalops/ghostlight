import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const builder = path.join(root, "tools/build-readiness-ledger.mjs");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "ghostlight-readiness-ledger-"));
const receiptPath = path.join(root, "docs/architecture.md");
const digest = crypto.createHash("sha256").update(fs.readFileSync(receiptPath)).digest("hex");
const manifestPath = path.join(temporary, "manifest.json");
const outputPath = path.join(temporary, "ledger.json");
const definitions = {
  remote_profile_continuity: ["profile_restored", "cookie_restored", "local_storage_restored"],
  decoded_media: ["four_phases", "frames_decoded", "dropped_frames_recorded", "selected_udp"],
  accepted_input: ["four_phases", "x11_input", "causal_pixel_marker"],
  singular_controller_ownership: ["one_owner", "controller_transfer", "cleanup"],
  sleep_wake_recovery: ["bounded_cycles", "deadline", "cleanup"],
  peripheral_readiness: ["origin_bound", "revocation", "os_permission_prompt", "content_free_audit"],
  real_account_persistence: ["explicit_witness", "profile_restored", "no_content_captured"],
};
const evidence = (id, passed = true) => ({
  receipt_path: "docs/architecture.md",
  receipt_sha256: digest,
  source_sha: "a".repeat(40),
  recorded_at: "2026-08-13T12:00:00Z",
  synthetic: id !== "real_account_persistence",
  consent: id === "real_account_persistence" ? "explicit" : "synthetic",
  gates: Object.fromEntries(definitions[id].map((gate) => [gate, passed])),
});
const manifest = () => ({ schema_version: 1, claims: Object.keys(definitions).map((id) => ({ id, evidence: [] })) });
const run = (value) => {
  fs.writeFileSync(manifestPath, JSON.stringify(value));
  return spawnSync(process.execPath, [builder, manifestPath, outputPath], { encoding: "utf8" });
};

try {
  const partial = manifest();
  partial.claims[0].evidence = [evidence(partial.claims[0].id)];
  let result = run(partial);
  assert.equal(result.status, 0, result.stderr);
  let ledger = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(ledger.status, "Needs a test");
  assert.equal(ledger.calendar_duration_gate, false);
  assert.equal(ledger.content_blind, true);
  assert.deepEqual(ledger.collected_content_fields, []);
  assert.equal(ledger.claims[0].status, "Proven");
  assert.equal(ledger.claims[1].status, "Needs a test");
  assert.equal(ledger.claims[0].evidence[0].receipt_path, undefined);
  assert.doesNotMatch(JSON.stringify(ledger), /receipt_path|private\.example|filename|screenshot|page_content|account_identifier/);

  const failed = manifest();
  failed.claims[0].evidence = [evidence(failed.claims[0].id, false)];
  result = run(failed);
  assert.equal(result.status, 0, result.stderr);
  ledger = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(ledger.status, "Failed");
  assert.equal(ledger.claims[0].status, "Failed");

  const recovered = manifest();
  const oldFailure = { ...evidence(recovered.claims[0].id, false), recorded_at: "2026-08-12T12:00:00Z" };
  const newProof = { ...evidence(recovered.claims[0].id, true), recorded_at: "2026-08-13T12:00:00Z" };
  recovered.claims[0].evidence = [oldFailure, newProof];
  result = run(recovered);
  assert.equal(result.status, 0, result.stderr);
  ledger = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(ledger.claims[0].status, "Proven");
  assert.equal(ledger.claims[0].evidence[0].recorded_at, newProof.recorded_at);

  const complete = manifest();
  for (const claim of complete.claims) claim.evidence = [evidence(claim.id)];
  result = run(complete);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(fs.readFileSync(outputPath, "utf8")).status, "Proven");

  const calendarGate = manifest();
  calendarGate.days = 7;
  result = run(calendarGate);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must contain only/i);

  const leakedField = manifest();
  leakedField.claims[0].evidence = [{ ...evidence(leakedField.claims[0].id), url: "https://private.example" }];
  result = run(leakedField);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must contain only/i);

  const forgedDigest = manifest();
  forgedDigest.claims[0].evidence = [{ ...evidence(forgedDigest.claims[0].id), receipt_sha256: "b".repeat(64) }];
  result = run(forgedDigest);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /digest/i);

  const syntheticAccount = manifest();
  syntheticAccount.claims.at(-1).evidence = [{ ...evidence("real_account_persistence"), synthetic: true, consent: "synthetic" }];
  result = run(syntheticAccount);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /real-account evidence requires/i);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
