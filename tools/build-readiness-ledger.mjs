import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [manifestPath, outputPath] = process.argv.slice(2);
if (!manifestPath || !outputPath) {
  throw new Error("usage: build-readiness-ledger.mjs <evidence-manifest-json> <output-json>");
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CLAIMS = new Map([
  ["remote_profile_continuity", ["profile_restored", "cookie_restored", "local_storage_restored"]],
  ["decoded_media", ["four_phases", "frames_decoded", "dropped_frames_recorded", "selected_udp"]],
  ["accepted_input", ["four_phases", "x11_input", "causal_pixel_marker"]],
  ["singular_controller_ownership", ["one_owner", "controller_transfer", "cleanup"]],
  ["sleep_wake_recovery", ["bounded_cycles", "deadline", "cleanup"]],
  ["peripheral_readiness", ["origin_bound", "revocation", "os_permission_prompt", "content_free_audit"]],
  ["real_account_persistence", ["explicit_witness", "profile_restored", "no_content_captured"]],
]);
const SHA_PATTERN = /^[0-9a-f]{40}$/;
const DIGEST_PATTERN = /^[0-9a-f]{64}$/;
const exactKeys = (value, expected, label) => {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(`${label} must contain only: ${wanted.join(", ")}`);
  }
};
const parseTimestamp = (value, label) => {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value) || !Number.isFinite(Date.parse(value))) {
    throw new Error(`${label} must be an ISO-8601 timestamp`);
  }
  return value;
};
const hashFile = (filename) => crypto.createHash("sha256").update(fs.readFileSync(filename)).digest("hex");

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
} catch (error) {
  throw new Error(`read readiness manifest: ${error.message}`);
}
exactKeys(manifest, ["schema_version", "claims"], "manifest");
if (manifest.schema_version !== 1 || !Array.isArray(manifest.claims)) throw new Error("manifest schema_version must be 1 and claims must be an array");
if (manifest.claims.length !== CLAIMS.size) throw new Error("manifest must contain every readiness claim exactly once");

const seen = new Set();
const claims = manifest.claims.map((claim, claimIndex) => {
  exactKeys(claim, ["id", "evidence"], `claim ${claimIndex + 1}`);
  if (!CLAIMS.has(claim.id) || seen.has(claim.id)) throw new Error(`claim ${claimIndex + 1} has an unknown or duplicate id`);
  seen.add(claim.id);
  if (!Array.isArray(claim.evidence) || claim.evidence.length > 10) throw new Error(`${claim.id} evidence must be an array of at most 10 receipts`);
  const requiredGates = CLAIMS.get(claim.id);
  const evidence = claim.evidence.map((item, evidenceIndex) => {
    const label = `${claim.id} evidence ${evidenceIndex + 1}`;
    exactKeys(item, ["receipt_path", "receipt_sha256", "source_sha", "recorded_at", "synthetic", "consent", "gates"], label);
    if (typeof item.receipt_path !== "string" || path.isAbsolute(item.receipt_path) || !item.receipt_path.startsWith("docs/")) throw new Error(`${label} receipt_path must be repository-relative under docs/`);
    const resolved = path.resolve(root, item.receipt_path);
    const docsRoot = `${fs.realpathSync(path.join(root, "docs"))}${path.sep}`;
    const realReceipt = fs.realpathSync(resolved);
    if (!realReceipt.startsWith(docsRoot) || !fs.statSync(realReceipt).isFile() || fs.lstatSync(resolved).isSymbolicLink()) throw new Error(`${label} receipt must be a regular file under docs/`);
    if (!DIGEST_PATTERN.test(item.receipt_sha256) || hashFile(realReceipt) !== item.receipt_sha256) throw new Error(`${label} receipt digest does not match`);
    if (!SHA_PATTERN.test(item.source_sha)) throw new Error(`${label} source_sha must be a lowercase 40-character commit id`);
    parseTimestamp(item.recorded_at, `${label} recorded_at`);
    if (typeof item.synthetic !== "boolean" || !["synthetic", "explicit"].includes(item.consent)) throw new Error(`${label} synthetic and consent fields are invalid`);
    if (item.synthetic !== (item.consent === "synthetic")) throw new Error(`${label} synthetic evidence must use synthetic consent; non-synthetic evidence requires explicit consent`);
    if (claim.id === "real_account_persistence" && (item.synthetic || item.consent !== "explicit")) throw new Error("real-account evidence requires an explicit non-synthetic witness");
    exactKeys(item.gates, requiredGates, `${label} gates`);
    if (Object.values(item.gates).some((value) => typeof value !== "boolean")) throw new Error(`${label} gates must be booleans`);
    return {
      receipt_sha256: item.receipt_sha256,
      source_sha: item.source_sha,
      recorded_at: item.recorded_at,
      synthetic: item.synthetic,
      consent: item.consent,
      gates: item.gates,
    };
  });
  evidence.sort((left, right) => Date.parse(right.recorded_at) - Date.parse(left.recorded_at));
  const status = evidence.length === 0
    ? "Needs a test"
    : Object.values(evidence[0].gates).includes(false) ? "Failed" : "Proven";
  return { id: claim.id, status, evidence };
});

if ([...CLAIMS.keys()].some((id) => !seen.has(id))) throw new Error("manifest is missing a readiness claim");
const overallStatus = claims.some((claim) => claim.status === "Failed")
  ? "Failed"
  : claims.some((claim) => claim.status === "Needs a test") ? "Needs a test" : "Proven";
const ledger = {
  schema_version: 1,
  status: overallStatus,
  calendar_duration_gate: false,
  content_blind: true,
  collected_content_fields: [],
  claims,
};
const forbiddenOutputKeys = new Set(["receipt_path", "url", "hostname", "filename", "screenshot", "dom", "page_content", "cookie", "credential", "account_identifier", "media"]);
const assertContentBlind = (value) => {
  if (Array.isArray(value)) return value.forEach(assertContentBlind);
  if (value === null || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (forbiddenOutputKeys.has(key)) throw new Error(`generated ledger contains forbidden content field ${key}`);
    assertContentBlind(child);
  }
};
assertContentBlind(ledger);
fs.mkdirSync(path.dirname(outputPath), { recursive: true, mode: 0o700 });
fs.writeFileSync(outputPath, `${JSON.stringify(ledger, null, 2)}\n`, { mode: 0o600 });
process.stdout.write(`readiness ledger: ${overallStatus}; ${claims.filter((claim) => claim.status === "Proven").length}/${claims.length} claims proven\n`);
