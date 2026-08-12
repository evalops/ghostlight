import { createHash } from "node:crypto";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import { Socket } from "node:net";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(join(ROOT_DIR, "tests", "acceptance", "package.json"));
const { chromium } = require("playwright");
const { ws: WebSocket } = require(join(ROOT_DIR, "tests", "acceptance", "node_modules", "playwright-core", "lib", "utilsBundle.js"));
const FIXTURE_PATH = join(ROOT_DIR, "tools", "performance-fixture.py");
const IMAGE = process.env.GHOSTLIGHT_PERFORMANCE_IMAGE ?? "ghcr.io/evalops/ghostlight-viewer@sha256:2d609085752e66e56f867caf92a357b13fa393155d6d3acd2e1ab538ef593a44";
const REMOTE = process.env.GHOSTLIGHT_PERFORMANCE_REMOTE_HOST ?? "developer@192.168.4.113";
const REMOTE_HOST = process.env.GHOSTLIGHT_PERFORMANCE_REMOTE_ADDRESS ?? "192.168.4.113";
const BIND_ADDRESS = process.env.GHOSTLIGHT_PERFORMANCE_BIND_ADDRESS ?? REMOTE_HOST;
const PORT_BASE = Number(process.env.GHOSTLIGHT_PERFORMANCE_PORT_BASE ?? 55000);
const USE_SSH_TUNNEL = process.env.GHOSTLIGHT_PERFORMANCE_SSH_TUNNEL !== "false";
const TARGET_FPS = Number(process.env.GHOSTLIGHT_PERFORMANCE_TARGET_FPS ?? 25);
const WIDTH = Number(process.env.GHOSTLIGHT_PERFORMANCE_WIDTH ?? 1920);
const HEIGHT = Number(process.env.GHOSTLIGHT_PERFORMANCE_HEIGHT ?? 1080);
const CPU_USED = Number(process.env.GHOSTLIGHT_PERFORMANCE_CPU_USED ?? 4);
const USE_DAMAGE = process.env.GHOSTLIGHT_PERFORMANCE_USE_DAMAGE === "true";
const BITRATE_KBPS = Number(process.env.GHOSTLIGHT_PERFORMANCE_BITRATE_KBPS ?? 3072);
const PHASE_SECONDS = Number(process.env.GHOSTLIGHT_PERFORMANCE_PHASE_SECONDS ?? 30);
const WARMUP_SECONDS = Number(process.env.GHOSTLIGHT_PERFORMANCE_WARMUP_SECONDS ?? 10);
const CDP_COMMAND_TIMEOUT_MS = Number(process.env.GHOSTLIGHT_PERFORMANCE_CDP_TIMEOUT_MS ?? 5000);
const CDP_MODE = process.env.GHOSTLIGHT_PERFORMANCE_CDP_MODE ?? "pipe";
const OUTPUT_DIR = process.env.GHOSTLIGHT_PERFORMANCE_OUTPUT_DIR ?? join(ROOT_DIR, "output", "playwright", "performance", `run-${Date.now()}`);
const DISPLAY_NAME = process.env.GHOSTLIGHT_PERFORMANCE_DISPLAY_NAME ?? "Ghostlight Performance";
const PASSWORD = process.env.GHOSTLIGHT_PERFORMANCE_NEKO_PASSWORD ?? "ghostlight-performance-user";
const CONTROL_JSON = process.env.GHOSTLIGHT_PERFORMANCE_CONTROL_JSON ?? "";
const SOURCE_SHA_OVERRIDE = process.env.GHOSTLIGHT_PERFORMANCE_SOURCE_SHA ?? "";
const RUN_ID = process.env.GHOSTLIGHT_PERFORMANCE_RUN_ID ?? `run-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
const PROJECT = (process.env.GHOSTLIGHT_PERFORMANCE_PROJECT ?? `ghostlight_perf_${Date.now()}_${Math.random().toString(16).slice(2, 7)}`).replace(/[^a-z0-9_-]/gi, "_").slice(0, 50);
const REMOTE_DIR = `/tmp/${PROJECT}`;
const VIEWER_PORT = PORT_BASE;
const WEBRTC_PORT = PORT_BASE + 1;
const CDP_PORT = PORT_BASE + 2;
const CLIENT_ADDRESS = process.env.GHOSTLIGHT_PERFORMANCE_CLIENT_ADDRESS ?? (USE_SSH_TUNNEL ? "127.0.0.1" : REMOTE_HOST);
const ICE_ADDRESS = process.env.GHOSTLIGHT_PERFORMANCE_ICE_ADDRESS ?? (USE_SSH_TUNNEL ? "127.0.0.1" : BIND_ADDRESS);
const VIEWER_URL = `http://${CLIENT_ADDRESS}:${VIEWER_PORT}`;
const CDP_URL = `http://${CLIENT_ADDRESS}:${CDP_PORT}`;
const REMOTE_FIXTURE_URL = "http://127.0.0.1:18083";

if (!Number.isInteger(PORT_BASE) || PORT_BASE < 1024 || PORT_BASE + 2 > 65535) throw new Error("GHOSTLIGHT_PERFORMANCE_PORT_BASE must leave three valid ports");
if (!Number.isInteger(TARGET_FPS) || TARGET_FPS < 1 || TARGET_FPS > 60) throw new Error("GHOSTLIGHT_PERFORMANCE_TARGET_FPS must be 1..60");
if (!Number.isInteger(WIDTH) || !Number.isInteger(HEIGHT) || WIDTH < 640 || HEIGHT < 480) throw new Error("performance resolution is invalid");
if (!Number.isInteger(CPU_USED) || CPU_USED < 0 || CPU_USED > 16) throw new Error("GHOSTLIGHT_PERFORMANCE_CPU_USED must be 0..16");
if (!Number.isInteger(BITRATE_KBPS) || BITRATE_KBPS < 128) throw new Error("GHOSTLIGHT_PERFORMANCE_BITRATE_KBPS must be at least 128");
if (!Number.isInteger(PHASE_SECONDS) || PHASE_SECONDS < 5) throw new Error("GHOSTLIGHT_PERFORMANCE_PHASE_SECONDS must be at least 5");
if (!Number.isInteger(CDP_COMMAND_TIMEOUT_MS) || CDP_COMMAND_TIMEOUT_MS < 100 || CDP_COMMAND_TIMEOUT_MS > 60000) throw new Error("GHOSTLIGHT_PERFORMANCE_CDP_TIMEOUT_MS must be 100..60000");
if (!new Set(["pipe", "tcp"]).has(CDP_MODE)) throw new Error("GHOSTLIGHT_PERFORMANCE_CDP_MODE must be pipe or tcp");

const command = (program, args, options = {}) => execFileSync(program, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...options });
const remoteCommand = (script, options = {}) => command("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", REMOTE, script], options);
const shellQuote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
const yamlQuote = (value) => JSON.stringify(String(value));
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function currentSource() {
  const sourceSha = command("git", ["-C", ROOT_DIR, "rev-parse", "--verify", "HEAD"]).trim();
  const status = command("git", ["-C", ROOT_DIR, "status", "--porcelain", "--untracked-files=all"]).trim();
  if (status) throw new Error(`exact-source measurement requires a clean source tree:\n${status}`);
  if (SOURCE_SHA_OVERRIDE && SOURCE_SHA_OVERRIDE !== sourceSha) {
    throw new Error(`GHOSTLIGHT_PERFORMANCE_SOURCE_SHA must match git rev-parse HEAD (${sourceSha})`);
  }
  return { sourceSha, sourceTree: "clean" };
}

function vp8Pipeline() {
  const bitrate = BITRATE_KBPS * 650;
  return [
    `ximagesrc display-name=:99.0 show-pointer=false use-damage=${USE_DAMAGE ? "true" : "false"}`,
    `! capsfilter caps=video/x-raw,framerate=${TARGET_FPS}/1 name=framerate`,
    "! videoconvert ! queue ! vp8enc name=encoder",
    "max-quantizer=20 end-usage=cbr threads=4 undershoot=95",
    `buffer-size=${BITRATE_KBPS * 4} buffer-initial-size=${BITRATE_KBPS * 2}`,
    `target-bitrate=${bitrate} cpu-used=${CPU_USED} deadline=1 buffer-optimal-size=${BITRATE_KBPS * 3}`,
    "keyframe-max-dist=25 min-quantizer=4 ! appsink name=appsink",
  ].join(" ");
}

function nekoConfig() {
  return [
    `desktop:\n  screen: ${yamlQuote(`${WIDTH}x${HEIGHT}@${TARGET_FPS}`)}`,
    "member:",
    "  provider: multiuser",
    `  multiuser:\n    admin_password: ${yamlQuote("ghostlight-performance-admin")}\n    user_password: ${yamlQuote(PASSWORD)}`,
    "session:",
    "  merciful_reconnect: true",
    "  implicit_hosting: false",
    "  cookie:",
    "    enabled: false",
    "capture:",
    "  video:",
    "    codec: vp8",
    "    ids: [main]",
    `    pipeline: ${yamlQuote(vp8Pipeline())}`,
    "",
  ].join("\n");
}

function composeConfig() {
  return `services:
  viewer:
    image: ${yamlQuote(IMAGE)}
    init: true
    hostname: ghostlight-performance-viewer
    restart: "no"
    shm_size: "2gb"
    security_opt:
      - apparmor=unconfined
    ports:
      - ${yamlQuote(`${BIND_ADDRESS}:${VIEWER_PORT}:8080/tcp`)}
      - ${yamlQuote(`${BIND_ADDRESS}:${WEBRTC_PORT}:${WEBRTC_PORT}/udp`)}
      - ${yamlQuote(`${BIND_ADDRESS}:${WEBRTC_PORT}:${WEBRTC_PORT}/tcp`)}
      - ${yamlQuote(`${BIND_ADDRESS}:${CDP_PORT}:9223/tcp`)}
    volumes:
      - ${yamlQuote(`${REMOTE_DIR}/profile:/home/neko/.config/chromium`)}
      - ${yamlQuote(`${REMOTE_DIR}/neko.yaml:/etc/neko/neko.yaml:ro`)}
      - ${yamlQuote(`${REMOTE_DIR}/chromium.conf:/etc/neko/supervisord/chromium.conf:ro`)}
      - ${yamlQuote(`${REMOTE_DIR}/performance-cdp-pipe.py:/usr/local/bin/ghostlight-performance-cdp-pipe.py:ro`)}
      - ${yamlQuote(`${REMOTE_DIR}/performance.conf:/etc/neko/supervisord/ghostlight-performance.conf:ro`)}
      - ${yamlQuote(`${REMOTE_DIR}/performance-fixture.py:/usr/local/bin/ghostlight-performance-fixture.py:ro`)}
    environment:
      NEKO_SERVER_BIND: "0.0.0.0:8080"
      NEKO_WEBRTC_UDPMUX: ${yamlQuote(String(WEBRTC_PORT))}
      NEKO_WEBRTC_TCPMUX: ${yamlQuote(String(WEBRTC_PORT))}
      NEKO_WEBRTC_ICELITE: "0"
      NEKO_WEBRTC_NAT1TO1: ${yamlQuote(ICE_ADDRESS)}
      NEKO_LEGACY: "true"
    healthcheck:
      test: ["CMD-SHELL", "curl --fail --silent --show-error http://127.0.0.1:8080/health >/dev/null || exit 1"]
      interval: 5s
      timeout: 5s
      start_period: 20s
      retries: 24
`;
}

function chromiumConfig() {
  const chromiumCommand = "/usr/bin/chromium --no-sandbox --display=:99.0 --user-data-dir=/home/neko/.config/chromium --no-first-run --start-maximized --bwsi --enable-automation --force-dark-mode --disable-file-system --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage";
  const command = CDP_MODE === "pipe"
    ? `/usr/bin/python3 /usr/local/bin/ghostlight-performance-cdp-pipe.py --bind 0.0.0.0 --port 9222 -- ${chromiumCommand} --remote-debugging-pipe`
    : `${chromiumCommand} --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --remote-allow-origins=*`;
  return [
    "[program:chromium]",
    "environment=HOME=\"/home/neko\",USER=\"neko\",DISPLAY=\":99.0\"",
    `command=${command}`,
    "stopsignal=INT",
    "user=neko",
    "autostart=true",
    "autorestart=true",
    "priority=20",
    "stdout_logfile=/dev/fd/1",
    "stdout_logfile_maxbytes=0",
    "stderr_logfile=/dev/fd/2",
    "stderr_logfile_maxbytes=0",
    "",
    "[program:openbox]",
    "environment=HOME=\"/home/neko\",USER=\"neko\",DISPLAY=\":99.0\"",
    "command=/usr/bin/openbox --config-file /etc/neko/openbox.xml",
    "user=neko",
    "autostart=true",
    "autorestart=true",
    "priority=10",
    "stdout_logfile=/dev/fd/1",
    "stdout_logfile_maxbytes=0",
    "stderr_logfile=/dev/fd/2",
    "stderr_logfile_maxbytes=0",
    "",
  ].join("\n");
}

function supervisorConf() {
  return [
    "[program:ghostlight-performance-fixture]",
    "command=/usr/bin/python3 /usr/local/bin/ghostlight-performance-fixture.py",
    "user=neko",
    "priority=40",
    "autostart=true",
    "autorestart=true",
    "stdout_logfile=/dev/fd/1",
    "stdout_logfile_maxbytes=0",
    "stderr_logfile=/dev/fd/2",
    "stderr_logfile_maxbytes=0",
    "",
  ].join("\n");
}

async function writeRemoteFiles() {
  await fs.mkdir(OUTPUT_DIR, { recursive: true });
  const localConfigDir = join(OUTPUT_DIR, "remote-config");
  await fs.mkdir(localConfigDir, { recursive: true, mode: 0o700 });
  const files = {
    "neko.yaml": nekoConfig(),
    "chromium.conf": chromiumConfig(),
    "performance.conf": supervisorConf(),
  };
  const localPaths = [];
  for (const [name, contents] of Object.entries(files)) {
    const localPath = join(localConfigDir, name);
    await fs.writeFile(localPath, contents, { mode: name.endsWith(".py") ? 0o700 : 0o600 });
    localPaths.push(localPath);
  }
  const localFixture = join(localConfigDir, "performance-fixture.py");
  await fs.copyFile(FIXTURE_PATH, localFixture);
  await fs.chmod(localFixture, 0o700);
  const localCdpPipe = join(localConfigDir, "performance-cdp-pipe.py");
  await fs.copyFile(join(ROOT_DIR, "tools", "performance-cdp-pipe.py"), localCdpPipe);
  await fs.chmod(localCdpPipe, 0o700);
  const localCompose = join(localConfigDir, "compose.yaml");
  await fs.writeFile(localCompose, composeConfig(), { mode: 0o600 });
  await fs.writeFile(join(OUTPUT_DIR, "source.sha"), `${currentSource().sourceSha}\n`);
  await fs.writeFile(join(OUTPUT_DIR, "image.txt"), `${IMAGE}\n`);

  remoteCommand(`rm -rf -- ${shellQuote(REMOTE_DIR)} && mkdir -m 700 -p -- ${shellQuote(`${REMOTE_DIR}/profile`)}`);
  const remoteFiles = [...localPaths, localFixture, localCdpPipe, localCompose];
  command("scp", ["-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", ...remoteFiles, `${REMOTE}:${REMOTE_DIR}/`]);
  remoteCommand(`chmod 600 -- ${shellQuote(`${REMOTE_DIR}/neko.yaml`)} ${shellQuote(`${REMOTE_DIR}/chromium.conf`)} ${shellQuote(`${REMOTE_DIR}/performance.conf`)} ${shellQuote(`${REMOTE_DIR}/compose.yaml`)} && chmod 700 -- ${shellQuote(`${REMOTE_DIR}/performance-fixture.py`)} ${shellQuote(`${REMOTE_DIR}/performance-cdp-pipe.py`)}`);
  return { localConfigDir, localCompose };
}

async function waitForHTTP(url, timeoutMs = 120000, tunnel = null) {
  const deadline = Date.now() + timeoutMs;
  let lastError = "not attempted";
  while (Date.now() < deadline) {
    if (tunnel?.exitCode !== null) {
      throw new Error(`SSH tunnel exited while waiting for ${url} (code ${tunnel.exitCode}): ${tunnel.getStderr?.() ?? "no stderr"}`);
    }
    try {
      const response = await fetch(url);
      if (response.ok) return response;
      lastError = `HTTP ${response.status}`;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
    await sleep(1000);
  }
  throw new Error(`timed out waiting for ${url}: ${lastError}`);
}

async function startRemote() {
  remoteCommand(`docker compose --project-name ${shellQuote(PROJECT)} --file ${shellQuote(`${REMOTE_DIR}/compose.yaml`)} up --detach --wait --wait-timeout 180`);
  const containerId = remoteCommand(`docker compose --project-name ${shellQuote(PROJECT)} --file ${shellQuote(`${REMOTE_DIR}/compose.yaml`)} ps --quiet viewer`).trim();
  if (!containerId) throw new Error("the performance viewer container did not start");
  const inspect = JSON.parse(remoteCommand(`docker inspect ${shellQuote(containerId)}`).trim())[0];
  if (inspect.Config?.Image !== IMAGE) throw new Error(`viewer image mismatch: expected ${IMAGE}, got ${inspect.Config?.Image ?? "missing"}`);
  await fs.writeFile(join(OUTPUT_DIR, "container-inspect.json"), `${JSON.stringify(inspect, null, 2)}\n`);
  return { containerId, imageId: inspect.Image, containerName: inspect.Name };
}

function startRemoteStats(containerId) {
  const marker = `${REMOTE_DIR}/stats.running`;
  remoteCommand(`touch -- ${shellQuote(marker)}`);
  const statsPath = join(OUTPUT_DIR, "container-stats.jsonl");
  const stream = fsSync.createWriteStream(statsPath, { mode: 0o600 });
  const loop = `while test -f ${shellQuote(marker)}; do sample="$(docker stats --no-stream --format '{{json .}}' ${shellQuote(containerId)})"; if test -n "$sample"; then printf '{"captured_at":"%s","stats":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$sample"; fi; sleep 1; done`;
  const sampler = spawn("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", REMOTE, loop], { stdio: ["ignore", "pipe", "pipe"] });
  sampler.stdout.pipe(stream);
  let stderr = "";
  sampler.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
  return { marker, statsPath, sampler, stream, getStderr: () => stderr };
}

function startRemoteProcessStats(containerId) {
  const marker = `${REMOTE_DIR}/process-stats.running`;
  remoteCommand(`touch -- ${shellQuote(marker)}`);
  const statsPath = join(OUTPUT_DIR, "process-stats-timeseries.tsv");
  const stream = fsSync.createWriteStream(statsPath, { mode: 0o600 });
  const processScript = `for stat_file in /proc/[0-9]*/stat; do
  test -r "$stat_file" || continue
  pid="\${stat_file#/proc/}"
  pid="\${pid%/stat}"
  stat="$(cat "$stat_file" 2>/dev/null)" || continue
  comm="\${stat#* (}"
  comm="\${comm%%) *}"
  fields="\${stat##*) }"
  set -- $fields
  test "$#" -ge 13 || continue
  printf '%s\\t%s\\t%s\\t%s\\n' "$pid" "$comm" "\${12}" "\${13}"
done`;
  const loop = `printf 'meta\\tclk_tck\\t%s\\n' "$(getconf CLK_TCK 2>/dev/null || printf 100)"; while test -f ${shellQuote(marker)}; do captured_at="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"; docker exec ${shellQuote(containerId)} sh -c ${shellQuote(processScript)} | while IFS="$(printf '\\t')" read -r pid comm utime stime; do printf 'sample\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$captured_at" "$pid" "$comm" "$utime" "$stime"; done; sleep 1; done`;
  const sampler = spawn("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", REMOTE, loop], { stdio: ["ignore", "pipe", "pipe"] });
  sampler.stdout.pipe(stream);
  let stderr = "";
  sampler.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
  return { marker, statsPath, sampler, stream, getStderr: () => stderr };
}

function startRemoteCdpBridge(containerId) {
  const containerPid = remoteCommand(`docker inspect --format '{{.State.Pid}}' ${shellQuote(containerId)}`).trim();
  if (!/^\d+$/.test(containerPid)) throw new Error(`invalid viewer container PID for CDP bridge: ${containerPid}`);
  const logPath = `${REMOTE_DIR}/cdp-bridge.log`;
  const bridgeCommand = `nohup nsenter -t ${containerPid} -n -- /usr/bin/socat TCP-LISTEN:9223,bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:9222 </dev/null >${logPath} 2>&1 & echo $!`;
  const bridgePid = remoteCommand(`sudo -n sh -c ${shellQuote(bridgeCommand)}`).trim();
  if (!/^\d+$/.test(bridgePid)) throw new Error(`invalid CDP bridge PID: ${bridgePid}`);
  return { containerPid, bridgePid, logPath };
}

function stopRemoteCdpBridge(bridge) {
  if (!bridge) return;
  try { remoteCommand(`sudo -n kill ${shellQuote(bridge.bridgePid)}`); } catch { /* bridge may already have exited */ }
}

function startSshTunnel() {
  if (!USE_SSH_TUNNEL) return null;
  const forwardedPorts = [VIEWER_PORT, WEBRTC_PORT, CDP_PORT];
  assertLocalPorts(forwardedPorts, "before SSH tunnel spawn");
  const forwards = [
    `127.0.0.1:${VIEWER_PORT}:${BIND_ADDRESS}:${VIEWER_PORT}`,
    `127.0.0.1:${WEBRTC_PORT}:${BIND_ADDRESS}:${WEBRTC_PORT}`,
    `127.0.0.1:${CDP_PORT}:${BIND_ADDRESS}:${CDP_PORT}`,
  ];
  const tunnel = spawn("ssh", [
    "-4", "-N", "-o", "AddressFamily=inet", "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
    ...forwards.flatMap((forward) => ["-L", forward]),
    REMOTE,
  ], { stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  tunnel.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
  tunnel.getStderr = () => stderr;
  tunnel.forwardedPorts = forwardedPorts;
  return tunnel;
}

function localPortListeners(ports) {
  return ports.map((port) => {
    try {
      return { port, listeners: command("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"]).trim() };
    } catch (error) {
      if (error?.status === 1) return { port, listeners: "" };
      throw error;
    }
  });
}

function assertLocalPorts(ports, phase) {
  const occupied = localPortListeners(ports).filter((entry) => entry.listeners);
  if (occupied.length) {
    throw new Error(`${phase}: local TCP port(s) already in use: ${occupied.map((entry) => `${entry.port} by ${entry.listeners}`).join(", ")}`);
  }
}

async function waitForSshTunnel(tunnel) {
  if (!tunnel) return;
  await sleep(500);
  if (tunnel.exitCode !== null) throw new Error(`SSH tunnel exited before the client connected (code ${tunnel.exitCode}): ${tunnel.getStderr?.() ?? "no stderr"}`);
  const missing = localPortListeners(tunnel.forwardedPorts).filter((entry) => !entry.listeners);
  if (missing.length) throw new Error(`SSH tunnel did not bind expected IPv4 local port(s): ${missing.map((entry) => entry.port).join(", ")}; stderr: ${tunnel.getStderr?.() ?? "no stderr"}`);
}

async function stopSshTunnel(tunnel) {
  if (!tunnel) return;
  if (!tunnel.killed) tunnel.kill("SIGTERM");
  await new Promise((resolve) => {
    const timeout = setTimeout(resolve, 1000);
    tunnel.once("close", () => { clearTimeout(timeout); resolve(); });
  });
}

async function stopRemoteStats(stats) {
  if (!stats) return;
  try { remoteCommand(`rm -f -- ${shellQuote(stats.marker)}`); } catch { /* cleanup continues below */ }
  await new Promise((resolve) => {
    if (stats.sampler.exitCode !== null) return resolve();
    stats.sampler.once("close", resolve);
  });
  await new Promise((resolve) => stats.stream.end(resolve));
  if (stats.getStderr()) await fs.writeFile(join(OUTPUT_DIR, "container-stats.stderr"), stats.getStderr());
}

async function stopRemoteProcessStats(stats) {
  if (!stats) return;
  try { remoteCommand(`rm -f -- ${shellQuote(stats.marker)}`); } catch { /* cleanup continues below */ }
  await new Promise((resolve) => {
    if (stats.sampler.exitCode !== null) return resolve();
    stats.sampler.once("close", resolve);
  });
  await new Promise((resolve) => stats.stream.end(resolve));
  if (stats.getStderr()) await fs.writeFile(join(OUTPUT_DIR, "process-stats-timeseries.stderr"), stats.getStderr());
}

function parseCpu(value) {
  const parsed = Number.parseFloat(String(value).replace("%", ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function parseMemoryMiB(value) {
  const match = String(value).trim().match(/^([0-9.]+)\s*(B|KiB|MiB|GiB)$/i);
  if (!match) return null;
  const amount = Number(match[1]);
  const unit = match[2].toLowerCase();
  if (!Number.isFinite(amount)) return null;
  if (unit === "b") return amount / (1024 * 1024);
  if (unit === "kib") return amount / 1024;
  if (unit === "gib") return amount * 1024;
  return amount;
}

async function processSnapshot(containerId, label) {
  const capturedAt = new Date().toISOString();
  let text = "";
  try { text = remoteCommand(`docker top ${shellQuote(containerId)} -eo pid,comm,pcpu,pmem`); } catch (error) { text = `error: ${error instanceof Error ? error.message : String(error)}`; }
  await fs.writeFile(join(OUTPUT_DIR, `process-stats-${label}.txt`), text, { mode: 0o600 });
  const processes = text.split(/\r?\n/).slice(1).map((line) => {
    const match = line.trim().match(/^(\d+)\s+(\S+)\s+([0-9.]+)\s+([0-9.]+)/);
    return match ? { pid: Number(match[1]), command: match[2], cpu_pct: Number(match[3]), memory_pct: Number(match[4]) } : null;
  }).filter(Boolean);
  return { label, captured_at: capturedAt, processes, process_cpu_sum_pct: processes.reduce((sum, process) => sum + process.cpu_pct, 0) };
}

function readContainerStats(statsPath) {
  if (!fsSync.existsSync(statsPath)) return [];
  return fsSync.readFileSync(statsPath, "utf8").split(/\r?\n/).map((line) => {
    if (!line.trim()) return null;
    try {
      const envelope = JSON.parse(line);
      const parsed = envelope.stats ?? envelope;
      return {
        captured_at: envelope.captured_at ?? null,
        cpu_pct: parseCpu(parsed.CPUPerc),
        memory_mib: parseMemoryMiB(String(parsed.MemUsage ?? "").split("/")[0]),
        memory_pct: parseCpu(parsed.MemPerc),
        raw: parsed,
      };
    } catch { return null; }
  }).filter((sample) => sample && sample.cpu_pct !== null);
}

function processCategory(commandName) {
  const name = String(commandName).toLowerCase();
  if (name === "neko" || name.includes("neko")) return "neko";
  if (name.includes("chrom") || name.includes("chrome_crashpad")) return "chromium";
  if (name.includes("xorg") || name.includes("openbox") || name.includes("xwayland")) return "x-related";
  if (name.includes("gst") || name.includes("vp8enc")) return "gstreamer-external";
  return "other";
}

function readProcessTimeSeries(statsPath) {
  if (!fsSync.existsSync(statsPath)) return { clk_tck: null, samples: [] };
  const previous = new Map();
  const grouped = new Map();
  let clkTck = null;
  for (const line of fsSync.readFileSync(statsPath, "utf8").split(/\r?\n/)) {
    if (!line.trim()) continue;
    const fields = line.split("\t");
    if (fields[0] === "meta" && fields[1] === "clk_tck") {
      const parsed = Number(fields[2]);
      if (Number.isFinite(parsed) && parsed > 0) clkTck = parsed;
      continue;
    }
    if (fields[0] !== "sample" || fields.length < 6) continue;
    const [, capturedAt, pid, commandName, utimeText, stimeText] = fields;
    const capturedMs = Date.parse(capturedAt);
    const totalTicks = Number(utimeText) + Number(stimeText);
    if (!Number.isFinite(capturedMs) || !Number.isFinite(totalTicks)) continue;
    const key = String(pid);
    const prior = previous.get(key);
    const elapsedSeconds = prior ? (capturedMs - prior.capturedMs) / 1000 : 0;
    const deltaTicks = prior ? totalTicks - prior.totalTicks : 0;
    const cpuPct = clkTck && elapsedSeconds > 0 && deltaTicks >= 0 ? (deltaTicks / clkTck / elapsedSeconds) * 100 : null;
    previous.set(key, { capturedMs, totalTicks });
    const sample = grouped.get(capturedAt) ?? { captured_at: capturedAt, processes: [], category_cpu_pct: {} };
    const category = processCategory(commandName);
    sample.processes.push({ pid: Number(pid), command: commandName, category, cpu_time_ticks: totalTicks, cpu_pct: cpuPct });
    if (Number.isFinite(cpuPct)) sample.category_cpu_pct[category] = (sample.category_cpu_pct[category] ?? 0) + cpuPct;
    grouped.set(capturedAt, sample);
  }
  return { clk_tck: clkTck, samples: [...grouped.values()].sort((left, right) => Date.parse(left.captured_at) - Date.parse(right.captured_at)) };
}

function samplesInWindow(samples, phaseStart, phaseEnd) {
  const startMs = Date.parse(phaseStart);
  const endMs = Date.parse(phaseEnd);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) return [];
  return samples.filter((sample) => {
    const capturedMs = Date.parse(sample.captured_at ?? "");
    return Number.isFinite(capturedMs) && capturedMs >= startMs && capturedMs <= endMs;
  });
}

function aggregateResourceStats(samples) {
  return {
    resource_sample_count: samples.length,
    resource_sample_start: samples.at(0)?.captured_at ?? null,
    resource_sample_end: samples.at(-1)?.captured_at ?? null,
    viewer_cpu_median_pct: median(samples.map((sample) => sample.cpu_pct)),
    viewer_cpu_p95_pct: percentile(samples.map((sample) => sample.cpu_pct), 0.95),
    viewer_memory_p95_mib: percentile(samples.map((sample) => sample.memory_mib), 0.95),
    process_container_cpu_samples: samples.length,
  };
}

function summarizeProcessSamples(samples) {
  const categoryValues = new Map();
  for (const sample of samples) {
    for (const [category, value] of Object.entries(sample.category_cpu_pct ?? {})) {
      const values = categoryValues.get(category) ?? [];
      values.push(value);
      categoryValues.set(category, values);
    }
  }
  return {
    sample_count: samples.length,
    captured_at_start: samples.at(0)?.captured_at ?? null,
    captured_at_end: samples.at(-1)?.captured_at ?? null,
    category_cpu_pct_median: Object.fromEntries([...categoryValues.entries()].map(([category, values]) => [category, median(values)])),
    category_cpu_pct_p95: Object.fromEntries([...categoryValues.entries()].map(([category, values]) => [category, percentile(values, 0.95)])),
  };
}

function sorted(values) { return values.filter((value) => Number.isFinite(value)).sort((a, b) => a - b); }
function median(values) { const numbers = sorted(values); if (!numbers.length) return null; const middle = Math.floor(numbers.length / 2); return numbers.length % 2 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2; }
function percentile(values, rank) { const numbers = sorted(values); if (!numbers.length) return null; const index = (numbers.length - 1) * rank; const lower = Math.floor(index); const upper = Math.ceil(index); return numbers[lower] + (numbers[upper] - numbers[lower]) * (index - lower); }
function mean(values) { const numbers = values.filter((value) => Number.isFinite(value)); return numbers.length ? numbers.reduce((sum, value) => sum + value, 0) / numbers.length : null; }
function ratio(numerator, denominator) { return denominator > 0 ? numerator / denominator : null; }
function nonNegativeDelta(candidate, control) { return candidate === null || control === null ? null : candidate - control; }

function localWebSocketUrl(value) {
  const url = new URL(value);
  url.hostname = CLIENT_ADDRESS;
  return url.toString();
}

class RemoteCdpPage {
  constructor(target) {
    this.target = target;
    this.socket = null;
    this.nextId = 1;
    this.pending = new Map();
    this.events = new Map();
  }

  async connect() {
    this.socket = new WebSocket(localWebSocketUrl(this.target.webSocketDebuggerUrl));
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`remote CDP websocket open timed out after ${CDP_COMMAND_TIMEOUT_MS}ms`)), CDP_COMMAND_TIMEOUT_MS);
      this.socket.once("open", () => { clearTimeout(timeout); resolve(); });
      this.socket.once("error", (error) => { clearTimeout(timeout); reject(error); });
    });
    this.socket.on("message", (message) => {
      const packet = JSON.parse(message.toString());
      if (packet.id && this.pending.has(packet.id)) {
        const { resolve, reject } = this.pending.get(packet.id);
        this.pending.delete(packet.id);
        if (packet.error) reject(new Error(`${packet.error.code}: ${packet.error.message}`));
        else resolve(packet.result);
        return;
      }
      for (const listener of this.events.get(packet.method) ?? []) listener(packet.params ?? {});
    });
    this.socket.once("close", () => {
      for (const { reject } of this.pending.values()) reject(new Error("remote CDP websocket closed"));
      this.pending.clear();
    });
    try {
      await this.send("Page.enable");
      await this.send("Runtime.enable");
    } catch (error) {
      this.socket.close();
      this.socket = null;
      throw error;
    }
    return this;
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`remote CDP command timed out after ${CDP_COMMAND_TIMEOUT_MS}ms: ${method}`));
      }, CDP_COMMAND_TIMEOUT_MS);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timeout); resolve(value); },
        reject: (error) => { clearTimeout(timeout); reject(error); },
      });
      try {
        this.socket.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  on(method, listener) {
    const listeners = this.events.get(method) ?? [];
    listeners.push(listener);
    this.events.set(method, listeners);
  }

  async goto(url) {
    const loaded = new Promise((resolve) => {
      const listener = () => resolve();
      this.on("Page.loadEventFired", listener);
    });
    await this.send("Page.navigate", { url });
    await Promise.race([loaded, sleep(10000)]);
  }

  async waitForSelector(selector, timeoutMs = 30000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await this.evaluate((target) => Boolean(document.querySelector(target)), selector)) return;
      await sleep(100);
    }
    throw new Error(`remote CDP page selector timed out: ${selector}`);
  }

  async evaluate(callback, argument) {
    const functionSource = callback.toString();
    const argumentSource = argument === undefined ? "undefined" : JSON.stringify(argument);
    const expression = `Promise.resolve((${functionSource})(${argumentSource}))`;
    const response = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true, userGesture: true });
    if (response.exceptionDetails) {
      const description = response.exceptionDetails.exception?.description || response.exceptionDetails.text || "remote evaluation failed";
      throw new Error(description);
    }
    return response.result?.value;
  }

  async close() {
    if (!this.socket) return;
    try { await this.send("Page.close"); } catch { /* the container teardown remains authoritative */ }
    this.socket.close();
    this.socket = null;
  }
}

class RemoteCdpPipePage {
  constructor() {
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.nextId = 1;
    this.pending = new Map();
    this.events = new Map();
    this.sessionId = null;
    this.target = null;
  }

  async connect() {
    this.socket = new Socket();
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`remote CDP pipe connection timed out after ${CDP_COMMAND_TIMEOUT_MS}ms`)), CDP_COMMAND_TIMEOUT_MS);
      this.socket.once("connect", () => { clearTimeout(timeout); resolve(); });
      this.socket.once("error", (error) => { clearTimeout(timeout); reject(error); });
      this.socket.connect(CDP_PORT, CLIENT_ADDRESS);
    });
    this.socket.setNoDelay(true);
    this.socket.on("data", (chunk) => this.dispatch(chunk));
    this.socket.once("close", () => {
      for (const { reject } of this.pending.values()) reject(new Error("remote CDP pipe closed"));
      this.pending.clear();
    });
    const created = await this.send("Target.createTarget", { url: REMOTE_FIXTURE_URL });
    const targetId = created.targetId;
    if (!targetId) throw new Error("remote CDP pipe did not return a target id");
    const targetInfos = (await this.send("Target.getTargets")).targetInfos ?? [];
    this.target = targetInfos.find((entry) => entry.targetId === targetId) ?? { targetId, type: "page", url: REMOTE_FIXTURE_URL };
    const attached = await this.send("Target.attachToTarget", { targetId, flatten: true });
    if (!attached.sessionId) throw new Error("remote CDP pipe did not return a page session id");
    this.sessionId = attached.sessionId;
    await this.send("Target.activateTarget", { targetId });
    await this.sendPage("Page.enable");
    await this.sendPage("Runtime.enable");
    return this;
  }

  dispatch(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const end = this.buffer.indexOf(0);
      if (end < 0) return;
      const payload = this.buffer.subarray(0, end).toString();
      this.buffer = this.buffer.subarray(end + 1);
      if (!payload) continue;
      const packet = JSON.parse(payload);
      if (packet.id !== undefined && this.pending.has(packet.id)) {
        const { resolve, reject } = this.pending.get(packet.id);
        this.pending.delete(packet.id);
        if (packet.error) reject(new Error(`${packet.error.code}: ${packet.error.message}`));
        else resolve(packet.result);
        continue;
      }
      for (const listener of this.events.get(packet.method) ?? []) listener(packet.params ?? {});
    }
  }

  send(method, params = {}, sessionId = null) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`remote CDP pipe command timed out after ${CDP_COMMAND_TIMEOUT_MS}ms: ${method}`));
      }, CDP_COMMAND_TIMEOUT_MS);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timeout); resolve(value); },
        reject: (error) => { clearTimeout(timeout); reject(error); },
      });
      try {
        const packet = { id, method, params };
        if (sessionId) packet.sessionId = sessionId;
        this.socket.write(`${JSON.stringify(packet)}\0`);
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  sendPage(method, params = {}) {
    return this.send(method, params, this.sessionId);
  }

  on(method, listener) {
    const listeners = this.events.get(method) ?? [];
    listeners.push(listener);
    this.events.set(method, listeners);
  }

  async goto(url) {
    const loaded = new Promise((resolve) => this.on("Page.loadEventFired", resolve));
    await this.sendPage("Page.navigate", { url });
    await Promise.race([loaded, sleep(10000)]);
  }

  async waitForSelector(selector, timeoutMs = 30000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await this.evaluate((target) => Boolean(document.querySelector(target)), selector)) return;
      await sleep(100);
    }
    throw new Error(`remote CDP page selector timed out: ${selector}`);
  }

  async evaluate(callback, argument) {
    const functionSource = callback.toString();
    const argumentSource = argument === undefined ? "undefined" : JSON.stringify(argument);
    const expression = `Promise.resolve((${functionSource})(${argumentSource}))`;
    const response = await this.sendPage("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true, userGesture: true });
    if (response.exceptionDetails) {
      const description = response.exceptionDetails.exception?.description || response.exceptionDetails.text || "remote evaluation failed";
      throw new Error(description);
    }
    return response.result?.value;
  }

  async close() {
    if (!this.socket) return;
    try { if (this.target?.targetId) await this.send("Target.closeTarget", { targetId: this.target.targetId }); } catch { /* container teardown remains authoritative */ }
    this.socket.end();
    this.socket = null;
  }
}

async function connectRemoteCdpPage() {
  if (CDP_MODE === "pipe") {
    const page = await new RemoteCdpPipePage().connect();
    return { page, target: { ...page.target, cdp_mode: "pipe" } };
  }
  const listResponse = await fetch(`${CDP_URL}/json/list`);
  if (!listResponse.ok) throw new Error(`CDP target list failed: HTTP ${listResponse.status}`);
  let targets = await listResponse.json();
  let target = targets.find((entry) => entry.type === "page" && !entry.url.startsWith("devtools://"));
  if (!target) {
    const newTargetResponse = await fetch(`${CDP_URL}/json/new?${encodeURIComponent(REMOTE_FIXTURE_URL)}`, { method: "PUT" });
    if (!newTargetResponse.ok) throw new Error(`CDP target creation failed: HTTP ${newTargetResponse.status}`);
    target = await newTargetResponse.json();
  }
  const page = await new RemoteCdpPage(target).connect();
  return { page, target };
}

function addPeerTracking(context) {
  return context.addInitScript(() => {
    const peers = [];
    const nativePeerConnection = window.RTCPeerConnection;
    window.__ghostlightPeerConnections = peers;
    window.__ghostlightH264Supported = Boolean(window.RTCRtpReceiver?.getCapabilities?.("video")?.codecs?.some((entry) => entry.mimeType.toLowerCase() === "video/h264"));
    if (!nativePeerConnection) return;
    const trackedPeerConnection = function (...args) {
      const peer = new nativePeerConnection(...args);
      peers.push(peer);
      return peer;
    };
    trackedPeerConnection.prototype = nativePeerConnection.prototype;
    Object.setPrototypeOf(trackedPeerConnection, nativePeerConnection);
    try {
      Object.defineProperty(window, "RTCPeerConnection", { configurable: true, value: trackedPeerConnection, writable: true });
    } catch {
      window.RTCPeerConnection = trackedPeerConnection;
    }
  });
}

async function collectPeerReports(page) {
  return page.evaluate(async () => {
    const reports = [];
    for (const peer of window.__ghostlightPeerConnections ?? []) {
      try {
        const report = await peer.getStats();
        report.forEach((entry) => reports.push({ ...entry }));
      } catch {
        // A connection can close while a sample is being collected.
      }
    }
    return { reports, h264Supported: Boolean(window.__ghostlightH264Supported) };
  });
}

function statsSnapshot(reports) {
  const inbound = reports.filter((entry) => entry.type === "inbound-rtp" && (entry.kind === "video" || entry.mediaType === "video"));
  const transports = reports.filter((entry) => entry.type === "transport");
  const pairs = new Map(reports.filter((entry) => entry.type === "candidate-pair").map((entry) => [entry.id, entry]));
  const candidates = new Map(reports.filter((entry) => entry.type === "local-candidate" || entry.type === "remote-candidate").map((entry) => [entry.id, entry]));
  const codecs = new Map(reports.filter((entry) => entry.type === "codec").map((entry) => [entry.id, entry]));
  const selectedPairId = transports.map((entry) => entry.selectedCandidatePairId).find(Boolean);
  const selectedPair = (selectedPairId && pairs.get(selectedPairId)) || reports.find((entry) => entry.type === "candidate-pair" && entry.selected) || reports.find((entry) => entry.type === "candidate-pair" && entry.state === "succeeded" && entry.nominated) || null;
  const localCandidate = selectedPair?.localCandidateId ? candidates.get(selectedPair.localCandidateId) : null;
  const remoteCandidate = selectedPair?.remoteCandidateId ? candidates.get(selectedPair.remoteCandidateId) : null;
  const totals = inbound.reduce((result, entry) => ({
    bytesReceived: result.bytesReceived + (entry.bytesReceived ?? 0),
    framesDecoded: result.framesDecoded + (entry.framesDecoded ?? 0),
    framesDropped: result.framesDropped + (entry.framesDropped ?? 0),
    packetsReceived: result.packetsReceived + (entry.packetsReceived ?? 0),
    packetsLost: result.packetsLost + (entry.packetsLost ?? 0),
    nackCount: result.nackCount + (entry.nackCount ?? 0),
    pliCount: result.pliCount + (entry.pliCount ?? 0),
    jitterBufferDelay: result.jitterBufferDelay + (entry.jitterBufferDelay ?? 0),
    jitterBufferEmittedCount: result.jitterBufferEmittedCount + (entry.jitterBufferEmittedCount ?? 0),
    totalDecodeTime: result.totalDecodeTime + (entry.totalDecodeTime ?? 0),
    framesPerSecond: Math.max(result.framesPerSecond, entry.framesPerSecond ?? 0),
    frameWidth: Math.max(result.frameWidth, entry.frameWidth ?? 0),
    frameHeight: Math.max(result.frameHeight, entry.frameHeight ?? 0),
    jitter: Math.max(result.jitter, entry.jitter ?? 0),
    powerEfficientDecoder: result.powerEfficientDecoder || entry.powerEfficientDecoder === true,
    hasPowerEfficientDecoderValue: result.hasPowerEfficientDecoderValue || typeof entry.powerEfficientDecoder === "boolean",
    codecIds: [...result.codecIds, entry.codecId].filter(Boolean),
  }), {
    bytesReceived: 0, framesDecoded: 0, framesDropped: 0, packetsReceived: 0, packetsLost: 0,
    nackCount: 0, pliCount: 0, jitterBufferDelay: 0, jitterBufferEmittedCount: 0, totalDecodeTime: 0,
    framesPerSecond: 0, frameWidth: 0, frameHeight: 0, jitter: 0, powerEfficientDecoder: false,
    hasPowerEfficientDecoderValue: false, codecIds: [],
  });
  const selectedCodec = totals.codecIds.map((id) => codecs.get(id)).find(Boolean) ?? null;
  return {
    inbound_count: inbound.length,
    active_media: inbound.length > 0 && totals.framesDecoded > 0 ? 1 : 0,
    ...totals,
    packet_loss_ratio: ratio(totals.packetsLost, totals.packetsReceived + totals.packetsLost),
    current_rtt_ms: selectedPair?.currentRoundTripTime == null ? null : selectedPair.currentRoundTripTime * 1000,
    jitter_ms: totals.jitter * 1000,
    mean_decode_ms: ratio(totals.totalDecodeTime * 1000, totals.framesDecoded),
    mean_processing_delay_ms: ratio(totals.jitterBufferDelay * 1000, totals.jitterBufferEmittedCount),
    frame_width: totals.frameWidth || null,
    frame_height: totals.frameHeight || null,
    power_efficient_decoder: totals.hasPowerEfficientDecoderValue ? totals.powerEfficientDecoder : null,
    codec: selectedCodec ? {
      id: selectedCodec.id,
      mime_type: selectedCodec.mimeType ?? null,
      clock_rate: selectedCodec.clockRate ?? null,
      sdp_fmtp_line: selectedCodec.sdpFmtpLine ?? null,
    } : null,
    selected_ice_pair: selectedPair ? {
      id: selectedPair.id,
      state: selectedPair.state ?? null,
      nominated: selectedPair.nominated ?? null,
      protocol: selectedPair.protocol ?? localCandidate?.protocol ?? null,
      local_candidate_type: localCandidate?.candidateType ?? null,
      remote_candidate_type: remoteCandidate?.candidateType ?? null,
      local_address: localCandidate?.address ?? localCandidate?.ip ?? null,
      remote_address: remoteCandidate?.address ?? remoteCandidate?.ip ?? null,
    } : null,
    udp_transport_selected: (selectedPair?.protocol ?? localCandidate?.protocol ?? "").toLowerCase() === "udp",
  };
}

async function installFrameObserver(page) {
  await page.evaluate(() => {
    const video = document.querySelector("video");
    if (!video) throw new Error("viewer video element is missing");
    const canvas = document.createElement("canvas");
    canvas.width = 320;
    canvas.height = 180;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    const state = {
      samples: [],
      markerSeenAt: 0,
      markerClearSeenAt: 0,
      markerLastVisible: false,
      markerArmed: false,
    };
    window.__ghostlightFrameState = state;
    const inspect = (now, metadata = {}) => {
      let markerVisible = false;
      try {
        context.drawImage(video, 0, 0, canvas.width, canvas.height);
        const pixels = context.getImageData(0, 0, 160, 60).data;
        let brightGreen = 0;
        for (let index = 0; index < pixels.length; index += 4) {
          const [red, green, blue] = pixels.slice(index, index + 3);
          if (green > 150 && green > red * 1.45 && green > blue * 1.15 && red < 150) brightGreen += 1;
        }
        markerVisible = brightGreen > 80;
      } catch {
        markerVisible = false;
      }
      if (!markerVisible) state.markerClearSeenAt = now;
      if (markerVisible && state.markerArmed && !state.markerLastVisible) state.markerSeenAt = now;
      state.markerLastVisible = markerVisible;
      state.samples.push({
        now,
        presentation_time: metadata.presentationTime ?? null,
        expected_display_time: metadata.expectedDisplayTime ?? null,
        processing_duration: metadata.processingDuration ?? null,
        presented_frames: metadata.presentedFrames ?? null,
        media_time: metadata.mediaTime ?? null,
        width: metadata.width ?? video.videoWidth ?? null,
        height: metadata.height ?? video.videoHeight ?? null,
        marker_visible: markerVisible,
      });
      if (state.samples.length > 5000) state.samples.splice(0, state.samples.length - 5000);
    };
    const callback = (now, metadata) => {
      inspect(now, metadata);
      if ("requestVideoFrameCallback" in video) video.requestVideoFrameCallback(callback);
    };
    if ("requestVideoFrameCallback" in video) video.requestVideoFrameCallback(callback);
    else requestAnimationFrame((now) => callback(now, {}));
  });
}

async function resetFrameState(page) {
  await page.evaluate(() => {
    const state = window.__ghostlightFrameState;
    if (!state) return;
    state.samples = [];
    state.markerSeenAt = 0;
    state.markerClearSeenAt = 0;
    state.markerLastVisible = false;
    state.markerArmed = false;
  });
}

async function resetRemoteMarker(clientPage, remotePage) {
  await remotePage.evaluate(() => window.__ghostlightResetMarker?.());
  await resetFrameState(clientPage);
  await clientPage.waitForFunction(() => (window.__ghostlightFrameState?.markerClearSeenAt ?? 0) > 0, null, { timeout: 2000 }).catch(() => {});
}

async function measureCausalMarker(clientPage, remotePage) {
  await resetRemoteMarker(clientPage, remotePage);
  const ready = await clientPage.evaluate(() => {
    const state = window.__ghostlightFrameState;
    if (!state || !state.markerClearSeenAt) return false;
    state.markerArmed = true;
    state.markerSeenAt = 0;
    state.inputDispatchAt = performance.now();
    return true;
  });
  if (!ready) return { success: false, input_to_present_ms: null };
  try {
    await clientPage.keyboard.press("F8");
    await clientPage.waitForFunction(() => (window.__ghostlightFrameState?.markerSeenAt ?? 0) > 0, null, { timeout: 2500 });
    const latency = await clientPage.evaluate(() => {
      const state = window.__ghostlightFrameState;
      return state.markerSeenAt - state.inputDispatchAt;
    });
    return { success: Number.isFinite(latency) && latency >= 0, input_to_present_ms: Number.isFinite(latency) ? latency : null };
  } catch {
    return { success: false, input_to_present_ms: null };
  }
}

async function collectClientStats(page) {
  const result = await collectPeerReports(page);
  return { ...statsSnapshot(result.reports), h264_supported: result.h264Supported, reports: result.reports };
}

async function remoteViewportPoint(remotePage, selector) {
  return remotePage.evaluate((target) => {
    const element = document.querySelector(target);
    if (!element) return null;
    const rect = element.getBoundingClientRect();
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, viewportWidth: innerWidth, viewportHeight: innerHeight };
  }, selector);
}

async function startRemoteWorkload(clientPage, remotePage, phase) {
  if (phase === "scrolling") {
    await remotePage.evaluate(() => {
      window.scrollTo(0, 0);
      window.__ghostlightWorkloadTimer = window.setInterval(() => window.scrollBy(0, 12), 16);
    });
    return async () => remotePage.evaluate(() => { window.clearInterval(window.__ghostlightWorkloadTimer); window.__ghostlightWorkloadTimer = 0; });
  }
  if (phase === "animation") {
    await remotePage.evaluate(() => document.querySelector("#animation-stage")?.scrollIntoView({ block: "start" }));
    return async () => {};
  }
  if (phase === "typing") {
    const target = await remoteViewportPoint(remotePage, "#typing-input");
    if (!target) throw new Error("typing fixture input is missing");
    const videoBox = await clientPage.locator("video").boundingBox();
    if (!videoBox) throw new Error("viewer video bounds are missing");
    const x = videoBox.x + (target.x / target.viewportWidth) * videoBox.width;
    const y = videoBox.y + (target.y / target.viewportHeight) * videoBox.height;
    await clientPage.mouse.click(x, y);
    let index = 0;
    let pending = Promise.resolve();
    const text = " synthetic review text";
    const timer = setInterval(() => {
      pending = pending.then(async () => {
        await clientPage.keyboard.type(`${text} ${index++}`, { delay: 2 });
      }).catch(() => {});
    }, 1200);
    return async () => { clearInterval(timer); await pending; };
  }
  return async () => {};
}

function framePhaseMetrics(frameState, durationSeconds) {
  const samples = frameState.samples ?? [];
  const intervals = samples.slice(1).map((sample, index) => sample.now - samples[index].now).filter((value) => Number.isFinite(value) && value > 0);
  const freezeThreshold = 1500 / TARGET_FPS;
  const freezeEvents = intervals.filter((value) => value > freezeThreshold).length;
  return {
    frame_sample_count: samples.length,
    frame_intervals_ms: intervals,
    freeze_events: freezeEvents,
    freeze_ratio: ratio(freezeEvents, Math.max(1, intervals.length)),
    frame_width: samples.at(-1)?.width ?? null,
    frame_height: samples.at(-1)?.height ?? null,
  };
}

async function runPhase(clientPage, remotePage, phase) {
  await remotePage.goto(`${REMOTE_FIXTURE_URL}/${phase}`, { waitUntil: "domcontentloaded" });
  await remotePage.waitForSelector("#causal-marker");
  await clientPage.waitForTimeout(WARMUP_SECONDS * 1000);
  await resetRemoteMarker(clientPage, remotePage);
  const startStats = await collectClientStats(clientPage);
  const startTime = Date.now();
  const stopWorkload = await startRemoteWorkload(clientPage, remotePage, phase);
  const markerReceipts = [];
  try {
    const deadline = startTime + PHASE_SECONDS * 1000;
    while (Date.now() < deadline) {
      const remaining = deadline - Date.now();
      await sleep(Math.min(3000, Math.max(250, remaining)));
      if (Date.now() <= deadline + 100) markerReceipts.push({ captured_at: new Date().toISOString(), ...(await measureCausalMarker(clientPage, remotePage)) });
    }
  } finally {
    await stopWorkload();
  }
  const endTime = Date.now();
  const endStats = await collectClientStats(clientPage);
  const elapsedSeconds = Math.max(0.001, (endTime - startTime) / 1000);
  const decodedFrames = Math.max(0, endStats.framesDecoded - startStats.framesDecoded);
  const droppedFrames = Math.max(0, endStats.framesDropped - startStats.framesDropped);
  const receivedBytes = Math.max(0, endStats.bytesReceived - startStats.bytesReceived);
  const packetsReceived = Math.max(0, endStats.packetsReceived - startStats.packetsReceived);
  const packetsLost = Math.max(0, endStats.packetsLost - startStats.packetsLost);
  const markerLatencies = markerReceipts.map((receipt) => receipt.input_to_present_ms).filter((value) => Number.isFinite(value));
  const frameMetrics = await clientPage.evaluate(() => window.__ghostlightFrameState ? structuredClone(window.__ghostlightFrameState) : { samples: [] });
  const frameSummary = framePhaseMetrics(frameMetrics, elapsedSeconds);
  return {
    phase,
    phase_start: new Date(startTime).toISOString(),
    phase_end: new Date(endTime).toISOString(),
    target_fps: TARGET_FPS,
    duration_seconds: elapsedSeconds,
    active_media: startStats.active_media && endStats.active_media && decodedFrames > 0 ? 1 : 0,
    actual_fps: decodedFrames / elapsedSeconds,
    actual_to_target_fps_ratio: ratio(decodedFrames / elapsedSeconds, TARGET_FPS),
    decoded_frames: decodedFrames,
    dropped_frames: droppedFrames,
    dropped_frame_ratio: ratio(droppedFrames, decodedFrames + droppedFrames),
    bytes_received: receivedBytes,
    bitrate_bps: receivedBytes * 8 / elapsedSeconds,
    packets_received: packetsReceived,
    packets_lost: packetsLost,
    packet_loss_ratio: ratio(packetsLost, packetsReceived + packetsLost),
    nack_count: Math.max(0, endStats.nackCount - startStats.nackCount),
    pli_count: Math.max(0, endStats.pliCount - startStats.pliCount),
    current_rtt_ms: endStats.current_rtt_ms,
    jitter_ms: endStats.jitter_ms,
    mean_decode_ms: endStats.mean_decode_ms,
    mean_processing_delay_ms: endStats.mean_processing_delay_ms,
    frame_width: endStats.frame_width ?? frameSummary.frame_width,
    frame_height: endStats.frame_height ?? frameSummary.frame_height,
    udp_transport_selected: endStats.udp_transport_selected,
    power_efficient_decoder: endStats.power_efficient_decoder,
    codec: endStats.codec,
    selected_ice_pair: endStats.selected_ice_pair,
    visual_event_attempts: markerReceipts.length,
    visual_event_successes: markerReceipts.filter((receipt) => receipt.success).length,
    visual_event_success_rate: ratio(markerReceipts.filter((receipt) => receipt.success).length, markerReceipts.length),
    input_to_present_median_ms: median(markerLatencies),
    input_to_present_p95_ms: percentile(markerLatencies, 0.95),
    input_to_present_receipts: markerReceipts,
    freeze_events: frameSummary.freeze_events,
    freeze_ratio: frameSummary.freeze_ratio,
    frame_sample_count: frameSummary.frame_sample_count,
    resource_sample_count: 0,
    resource_sample_start: null,
    resource_sample_end: null,
    viewer_cpu_median_pct: null,
    viewer_cpu_p95_pct: null,
    viewer_memory_p95_mib: null,
    process_container_cpu_samples: 0,
    process_cpu_attribution: null,
    raw_start_stats: startStats,
    raw_end_stats: endStats,
    raw_frame_samples: frameMetrics.samples,
  };
}

function aggregatePhases(phases) {
  const fields = ["actual_fps", "bitrate_bps", "current_rtt_ms", "jitter_ms", "mean_decode_ms", "mean_processing_delay_ms", "input_to_present_median_ms", "input_to_present_p95_ms", "freeze_ratio", "dropped_frame_ratio"];
  const aggregate = {};
  for (const field of fields) aggregate[field] = median(phases.map((phase) => phase[field]));
  aggregate.active_media = phases.length > 0 && phases.every((phase) => phase.active_media === 1) ? 1 : 0;
  aggregate.actual_to_target_fps_ratio = median(phases.map((phase) => phase.actual_to_target_fps_ratio));
  aggregate.visual_event_success_rate = ratio(phases.reduce((sum, phase) => sum + phase.visual_event_successes, 0), phases.reduce((sum, phase) => sum + phase.visual_event_attempts, 0));
  aggregate.freeze_ratio = mean(phases.map((phase) => phase.freeze_ratio));
  aggregate.dropped_frame_ratio = mean(phases.map((phase) => phase.dropped_frame_ratio));
  aggregate.viewer_cpu_median_pct = median(phases.map((phase) => phase.viewer_cpu_median_pct));
  aggregate.viewer_cpu_p95_pct = percentile(phases.map((phase) => phase.viewer_cpu_p95_pct), 0.95);
  aggregate.viewer_memory_p95_mib = percentile(phases.map((phase) => phase.viewer_memory_p95_mib), 0.95);
  aggregate.input_to_present_median_ms = median(phases.flatMap((phase) => phase.input_to_present_receipts.map((receipt) => receipt.input_to_present_ms)));
  aggregate.input_to_present_p95_ms = percentile(phases.flatMap((phase) => phase.input_to_present_receipts.map((receipt) => receipt.input_to_present_ms)), 0.95);
  aggregate.decoded_fps = aggregate.actual_fps;
  aggregate.frame_width = phases.find((phase) => phase.frame_width)?.frame_width ?? null;
  aggregate.frame_height = phases.find((phase) => phase.frame_height)?.frame_height ?? null;
  aggregate.udp_transport_selected = phases.length > 0 && phases.every((phase) => phase.udp_transport_selected === true);
  aggregate.power_efficient_decoder = phases.every((phase) => phase.power_efficient_decoder === true) ? true : phases.some((phase) => phase.power_efficient_decoder === false) ? false : null;
  aggregate.nack_count = phases.reduce((sum, phase) => sum + phase.nack_count, 0);
  aggregate.pli_count = phases.reduce((sum, phase) => sum + phase.pli_count, 0);
  aggregate.packet_loss_ratio = mean(phases.map((phase) => phase.packet_loss_ratio));
  aggregate.codec = phases.find((phase) => phase.codec)?.codec ?? null;
  aggregate.selected_ice_pairs = phases.map((phase) => phase.selected_ice_pair).filter(Boolean);
  return aggregate;
}

async function savePhaseScreenshot(page, phase) {
  const path = join(OUTPUT_DIR, `${phase}.png`);
  await page.screenshot({ path, animations: "disabled" });
  return path;
}

async function readControl() {
  if (!CONTROL_JSON) return null;
  const parsed = JSON.parse(await fs.readFile(CONTROL_JSON, "utf8"));
  return parsed.aggregate ?? parsed;
}

function buildGates(aggregate, control) {
  const controlFps = control?.actual_to_target_fps_ratio ?? 1;
  const controlDropped = control?.dropped_frame_ratio ?? aggregate.dropped_frame_ratio;
  const controlFreeze = control?.freeze_ratio ?? aggregate.freeze_ratio;
  const controlInputP95 = control?.input_to_present_p95_ms ?? aggregate.input_to_present_p95_ms;
  const inputRatio = controlInputP95 > 0 && aggregate.input_to_present_p95_ms !== null ? aggregate.input_to_present_p95_ms / controlInputP95 : control ? null : 1;
  return {
    active_media: aggregate.active_media === 1 ? 1 : 0,
    actual_to_target_fps_ratio: aggregate.actual_to_target_fps_ratio,
    dropped_frame_ratio_delta: nonNegativeDelta(aggregate.dropped_frame_ratio, controlDropped),
    freeze_ratio_delta: nonNegativeDelta(aggregate.freeze_ratio, controlFreeze),
    visual_event_success_rate: aggregate.visual_event_success_rate,
    input_to_present_p95_control_ratio: inputRatio,
    passed: aggregate.active_media === 1
      && aggregate.actual_to_target_fps_ratio !== null && aggregate.actual_to_target_fps_ratio >= 0.90
      && (control ? aggregate.dropped_frame_ratio !== null && controlDropped !== null && aggregate.dropped_frame_ratio <= controlDropped : true)
      && (control ? aggregate.freeze_ratio !== null && controlFreeze !== null && aggregate.freeze_ratio <= controlFreeze : true)
      && aggregate.visual_event_success_rate !== null && aggregate.visual_event_success_rate >= 0.99
      && inputRatio !== null && inputRatio <= 1,
  };
}

async function writeArtifactDigest(path) {
  const contents = await fs.readFile(path);
  const digest = createHash("sha256").update(contents).digest("hex");
  await fs.writeFile(`${path}.sha256`, `${digest}  ${path.split("/").at(-1)}\n`, { mode: 0o600 });
  return digest;
}

async function captureRemoteLogs(containerId) {
  if (!containerId) return null;
  try {
    const logs = remoteCommand(`docker logs --timestamps ${shellQuote(containerId)}`);
    const path = join(OUTPUT_DIR, "viewer.log");
    await fs.writeFile(path, logs, { mode: 0o600 });
    return path;
  } catch (error) {
    const path = join(OUTPUT_DIR, "viewer.log.error");
    await fs.writeFile(path, error instanceof Error ? error.message : String(error), { mode: 0o600 });
    return path;
  }
}

function sanitizePhase(phase) {
  const { raw_start_stats, raw_end_stats, raw_frame_samples, ...summary } = phase;
  return summary;
}

async function main() {
  const source = currentSource();
  await fs.mkdir(OUTPUT_DIR, { recursive: true });
  await fs.writeFile(join(OUTPUT_DIR, "run-config.json"), `${JSON.stringify({
    run_id: RUN_ID,
    image: IMAGE,
    remote: REMOTE,
    remote_host: REMOTE_HOST,
    bind_address: BIND_ADDRESS,
    client_address: CLIENT_ADDRESS,
    ice_address: ICE_ADDRESS,
    ssh_tunnel: USE_SSH_TUNNEL,
    transport_mode: USE_SSH_TUNNEL ? "ssh-tcp-smoke" : "direct-lan-udp-required",
    cdp_mode: CDP_MODE,
    ports: { viewer: VIEWER_PORT, webrtc: WEBRTC_PORT, cdp: CDP_PORT },
    target_fps: TARGET_FPS,
    resolution: `${WIDTH}x${HEIGHT}`,
    cpu_used: CPU_USED,
    use_damage: USE_DAMAGE,
    bitrate_kbps: BITRATE_KBPS,
    warmup_seconds: WARMUP_SECONDS,
    phase_seconds: PHASE_SECONDS,
  }, null, 2)}\n`, { mode: 0o600 });

  let remote;
  let remoteProvisioned = false;
  let tunnel;
  let cdpBridge;
  let stats;
  let processStats;
  let clientBrowser;
  let remotePage;
  let processStart;
  let processEnd;
  const phaseResults = [];
  const screenshots = [];
  let failure = null;
  try {
    await writeRemoteFiles();
    remoteProvisioned = true;
    remote = await startRemote();
    cdpBridge = startRemoteCdpBridge(remote.containerId);
    tunnel = startSshTunnel();
    await waitForSshTunnel(tunnel);
    processStart = await processSnapshot(remote.containerId, "start");
    await waitForHTTP(`${VIEWER_URL}/health`, 120000, tunnel);
    await waitForHTTP(`${CDP_URL}/json/version`, 120000, tunnel);
    stats = startRemoteStats(remote.containerId);
    processStats = startRemoteProcessStats(remote.containerId);

    clientBrowser = await chromium.launch({ headless: true, executablePath: process.env.GHOSTLIGHT_PERFORMANCE_BROWSER || undefined });
    const clientContext = await clientBrowser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
    await addPeerTracking(clientContext);
    const clientPage = await clientContext.newPage();
    await clientPage.goto(VIEWER_URL, { waitUntil: "domcontentloaded" });
    await clientPage.getByPlaceholder(/display name/i).fill(DISPLAY_NAME);
    await clientPage.getByPlaceholder(/password/i).fill(PASSWORD);
    await clientPage.getByRole("button", { name: /connect/i }).click();
    await clientPage.locator("video").waitFor({ state: "attached", timeout: 30000 });
    await clientPage.waitForFunction(() => {
      const video = document.querySelector("video");
      return video && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA;
    }, null, { timeout: 30000 });
    await installFrameObserver(clientPage);

    const remoteTarget = await connectRemoteCdpPage();
    remotePage = remoteTarget.page;
    await fs.writeFile(join(OUTPUT_DIR, "remote-cdp-target.json"), `${JSON.stringify(remoteTarget.target, null, 2)}\n`, { mode: 0o600 });
    const initialClientStats = await collectClientStats(clientPage);
    await fs.writeFile(join(OUTPUT_DIR, "initial-webrtc.json"), `${JSON.stringify({ ...initialClientStats, reports: undefined }, null, 2)}\n`, { mode: 0o600 });
    if (!initialClientStats.inbound_count) throw new Error("no inbound video RTP stream was negotiated");

    for (const phase of ["static-gmail", "scrolling", "typing", "animation"]) {
      const result = await runPhase(clientPage, remotePage, phase);
      phaseResults.push(result);
      await fs.writeFile(join(OUTPUT_DIR, `phase-${phase}.json`), `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
      screenshots.push(await savePhaseScreenshot(clientPage, phase));
    }
    if (!USE_SSH_TUNNEL && (!phaseResults.length || phaseResults.some((phase) => phase.selected_ice_pair?.protocol?.toLowerCase() !== "udp"))) {
      throw new Error("direct-LAN WebRTC receipt requires selected candidatePair protocol=udp in every phase");
    }
  } catch (error) {
    failure = error instanceof Error ? error : new Error(String(error));
  } finally {
    if (remotePage) await remotePage.close().catch(() => {});
    if (clientBrowser) await clientBrowser.close().catch(() => {});
    if (remote?.containerId) processEnd = await processSnapshot(remote.containerId, "end").catch((error) => ({ label: "end", captured_at: new Date().toISOString(), processes: [], process_cpu_sum_pct: null, error: error instanceof Error ? error.message : String(error) }));
    await stopRemoteStats(stats).catch(() => {});
    await stopRemoteProcessStats(processStats).catch(() => {});
    if (tunnel?.getStderr?.()) await fs.writeFile(join(OUTPUT_DIR, "ssh-tunnel.stderr"), tunnel.getStderr(), { mode: 0o600 });
    await stopSshTunnel(tunnel).catch(() => {});
    stopRemoteCdpBridge(cdpBridge);
    if (remote?.containerId) await captureRemoteLogs(remote.containerId).catch(() => {});
    if (remoteProvisioned) {
      try { remoteCommand(`docker compose --project-name ${shellQuote(PROJECT)} --file ${shellQuote(`${REMOTE_DIR}/compose.yaml`)} down --remove-orphans --volumes`); } catch { /* cleanup receipt records the run even if teardown fails */ }
      try { remoteCommand(`rm -rf -- ${shellQuote(REMOTE_DIR)}`); } catch { /* do not remove unrelated resources */ }
    }
  }

  const containerStats = stats ? readContainerStats(stats.statsPath) : [];
  const processTimeSeries = processStats ? readProcessTimeSeries(processStats.statsPath) : { clk_tck: null, samples: [] };
  for (const phase of phaseResults) {
    const phaseContainerStats = samplesInWindow(containerStats, phase.phase_start, phase.phase_end);
    Object.assign(phase, aggregateResourceStats(phaseContainerStats));
    const phaseProcessStats = samplesInWindow(processTimeSeries.samples, phase.phase_start, phase.phase_end);
    phase.process_cpu_attribution = {
      ...summarizeProcessSamples(phaseProcessStats),
      clk_tck: processTimeSeries.clk_tck,
      sampling_hz: 1,
      samples: phaseProcessStats,
    };
    await fs.writeFile(join(OUTPUT_DIR, `phase-${phase.phase}.json`), `${JSON.stringify(phase, null, 2)}\n`, { mode: 0o600 });
  }
  const aggregate = aggregatePhases(phaseResults);
  const control = await readControl().catch((error) => { failure ??= error; return null; });
  const gates = buildGates(aggregate, control);
  const result = {
    schema_version: 1,
    status: failure || !phaseResults.length || !gates.passed ? "blocked" : "measured",
    captured_at: new Date().toISOString(),
    run_id: RUN_ID,
    source,
    image: { reference: IMAGE, resolved_id: remote?.imageId ?? null },
    configuration: {
      resolution: `${WIDTH}x${HEIGHT}`,
      target_fps: TARGET_FPS,
      bitrate_kbps: BITRATE_KBPS,
      cpu_used: CPU_USED,
      use_damage: USE_DAMAGE,
      phase_seconds: PHASE_SECONDS,
      warmup_seconds: WARMUP_SECONDS,
      phases: ["static-gmail", "scrolling", "typing", "animation"],
    },
    viewer_cpu_median_pct: aggregate.viewer_cpu_median_pct,
    gates,
    diagnostics: {
      viewer_cpu_p95_pct: aggregate.viewer_cpu_p95_pct,
      viewer_memory_p95_mib: aggregate.viewer_memory_p95_mib,
      input_to_present_median_ms: aggregate.input_to_present_median_ms,
      input_to_present_p95_ms: aggregate.input_to_present_p95_ms,
      decoded_fps: aggregate.decoded_fps,
      bitrate_bps: aggregate.bitrate_bps,
      current_rtt_ms: aggregate.current_rtt_ms,
      jitter_ms: aggregate.jitter_ms,
      packet_loss_ratio: aggregate.packet_loss_ratio,
      nack_count: aggregate.nack_count,
      pli_count: aggregate.pli_count,
      mean_decode_ms: aggregate.mean_decode_ms,
      mean_processing_delay_ms: aggregate.mean_processing_delay_ms,
      frame_width: aggregate.frame_width,
      frame_height: aggregate.frame_height,
      udp_transport_selected: aggregate.udp_transport_selected,
      power_efficient_decoder: aggregate.power_efficient_decoder,
      active_media: aggregate.active_media,
      actual_to_target_fps_ratio: aggregate.actual_to_target_fps_ratio,
      dropped_frame_ratio: aggregate.dropped_frame_ratio,
      freeze_ratio: aggregate.freeze_ratio,
      visual_event_success_rate: aggregate.visual_event_success_rate,
      process_cpu_attribution: {
        start: processStart ?? null,
        end: processEnd ?? null,
        clk_tck: processTimeSeries.clk_tck,
        sampling_hz: 1,
        by_phase: Object.fromEntries(phaseResults.map((phase) => [phase.phase, phase.process_cpu_attribution])),
        samples: processTimeSeries.samples,
        boundary: "vp8enc runs in-process in Neko/GStreamer and is not separately attributable from the Neko process; no separate vp8enc CPU number is claimed.",
      },
      container_cpu_samples: containerStats,
      selected_ice_pairs: aggregate.selected_ice_pairs,
    },
    comparison: { paired_control: Boolean(control), control_source: CONTROL_JSON || null, control: control ?? null },
    phases: phaseResults.map(sanitizePhase),
    artifacts: {
      screenshots,
      per_phase_receipts: phaseResults.map((phase) => join(OUTPUT_DIR, `phase-${phase.phase}.json`)),
      container_stats: stats?.statsPath ?? null,
      process_time_series: processStats?.statsPath ?? null,
      process_start: join(OUTPUT_DIR, "process-stats-start.txt"),
      process_end: join(OUTPUT_DIR, "process-stats-end.txt"),
      viewer_log: join(OUTPUT_DIR, "viewer.log"),
    },
    limitations: [
      "Input-to-present is measured only when the remote fixture's causal marker changes after a WebRTC-client F8 dispatch; the old dispatch-to-next-presented-frame metric is not used or renamed.",
      "Viewer CPU is attributed to the exact pinned container through timestamped Docker stats sliced to each phase window; host-wide CPU is not substituted.",
      "Process CPU samples are captured at approximately 1 Hz from /proc utime+stime deltas. Chromium, Neko, X-related, and other categories are reported; vp8enc remains in-process within Neko/GStreamer and is not separately attributable.",
      USE_SSH_TUNNEL ? "SSH TCP forwarding is smoke-only and is not used as the 1080p25 control transport; a direct-LAN run must set GHOSTLIGHT_PERFORMANCE_SSH_TUNNEL=false and prove selected candidatePair protocol=udp." : "This receipt requires a direct-LAN selected candidatePair protocol=udp in every phase.",
      "The public pinned viewer image and software VP8 fallback were used. No software H.264 or VAAPI claim is made by this harness.",
    ],
    error: failure ? failure.message : null,
  };
  const receiptPath = join(OUTPUT_DIR, "receipt.json");
  await fs.writeFile(receiptPath, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
  await writeArtifactDigest(receiptPath);
  console.log(JSON.stringify(result, null, 2));
  if (result.status !== "measured") process.exitCode = 1;
}

function runSelfTests() {
  const samples = [
    { captured_at: "2026-08-12T00:00:00.000Z", cpu_pct: 10, memory_mib: 100 },
    { captured_at: "2026-08-12T00:00:01.000Z", cpu_pct: 20, memory_mib: 200 },
    { captured_at: "2026-08-12T00:00:02.000Z", cpu_pct: 80, memory_mib: 800 },
    { captured_at: "2026-08-12T00:00:03.000Z", cpu_pct: 90, memory_mib: 900 },
  ];
  const firstWindow = aggregateResourceStats(samplesInWindow(samples, "2026-08-12T00:00:00.000Z", "2026-08-12T00:00:01.000Z"));
  const secondWindow = aggregateResourceStats(samplesInWindow(samples, "2026-08-12T00:00:02.000Z", "2026-08-12T00:00:03.000Z"));
  assert.equal(firstWindow.resource_sample_count, 2);
  assert.equal(secondWindow.resource_sample_count, 2);
  assert.notEqual(firstWindow.viewer_cpu_median_pct, secondWindow.viewer_cpu_median_pct);
  assert.notEqual(firstWindow.viewer_memory_p95_mib, secondWindow.viewer_memory_p95_mib);

  const processSamples = [
    { captured_at: "2026-08-12T00:00:00.000Z", category_cpu_pct: { chromium: 1, neko: 2 } },
    { captured_at: "2026-08-12T00:00:01.000Z", category_cpu_pct: { chromium: 3, neko: 4 } },
    { captured_at: "2026-08-12T00:00:02.000Z", category_cpu_pct: { chromium: 7, neko: 8 } },
  ];
  const firstProcessWindow = summarizeProcessSamples(samplesInWindow(processSamples, "2026-08-12T00:00:00.000Z", "2026-08-12T00:00:01.000Z"));
  const secondProcessWindow = summarizeProcessSamples(samplesInWindow(processSamples, "2026-08-12T00:00:02.000Z", "2026-08-12T00:00:02.000Z"));
  assert.notEqual(firstProcessWindow.category_cpu_pct_median.chromium, secondProcessWindow.category_cpu_pct_median.chromium);
  console.log(JSON.stringify({ phase_window_resource_accounting: "passed", phase_window_process_accounting: "passed" }));
}

if (process.argv.includes("--self-test")) {
  try {
    runSelfTests();
  } catch (error) {
    console.error(error instanceof Error ? error.stack || error.message : String(error));
    process.exitCode = 1;
  }
} else {
  main().catch(async (error) => {
    const message = error instanceof Error ? error.stack || error.message : String(error);
    try {
      await fs.mkdir(OUTPUT_DIR, { recursive: true });
      await fs.writeFile(join(OUTPUT_DIR, "harness-error.txt"), `${message}\n`, { mode: 0o600 });
    } catch { /* preserve the original failure */ }
    console.error(message);
    process.exitCode = 1;
  });
}
