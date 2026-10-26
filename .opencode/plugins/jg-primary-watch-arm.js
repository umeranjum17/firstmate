import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeFirstmateOperationalInput } from "./lib/jg-operational-input.js";
// jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves here
for (const [_jgOld, _jgVal] of Object.entries(process.env))
  if (_jgOld.startsWith("FM_") && process.env[`JG_${_jgOld.slice(3)}`] === undefined)
    process.env[`JG_${_jgOld.slice(3)}`] = _jgVal;

// Supervision host: a home opted in with config/supervision-host
// (docs/configuration.md "Supervision host" owns the gate, which
// bin/jg-supervision-engine-lib.sh enabled answers; config/supervision-host-off opts out) spawns
// bin/jg-supervision-host.sh park --restart in the arm's place, which takes
// away-posture wakes itself and closes only when main is needed; its header
// owns the output read here. A "supervision-host:" line is actionable like a
// wake line, and the delivered message carries every such line in order while
// wake lines keep an eight-line cap. The host prints the first cycle's status
// line as soon as it is verified, so readiness and the handling handoff work
// as they do for the arm, with a longer readiness budget for the host's own
// startup. On a home that does not run the host nothing below changes.
const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
const WAKE_LINE = /^(signal:|stale:|check:|heartbeat($|:))/;
const HOST_LINE = /^supervision-host:/;
const ARM_RETIRE_TIMEOUT_MS = positiveInteger("JG_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const REARM_RETRY_BASE_MS = positiveInteger("JG_WATCH_REARM_RETRY_BASE_MS", 250);
const REARM_RETRY_MAX_MS = positiveInteger("JG_WATCH_REARM_RETRY_MAX_MS", 4000);
const REARM_RETRY_LIMIT = positiveInteger("JG_WATCH_REARM_RETRY_LIMIT", 5);

let child = null;
let armStatus = "idle";
let retryTimer = null;
let retryFailures = 0;
let launchInFlight = null;
let restorationInFlight = null;
let armClose = new WeakMap();
let armReadiness = new WeakMap();
let armRecovery = new WeakMap();
let armReadyBudget = new WeakMap();

function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function setArmStatus(status) {
  armStatus = status;
}

function waitForArmReady(armChild) {
  const readiness = armReadiness.get(armChild);
  if (!readiness) return Promise.resolve("failed");
  const timeout = armReadyBudget.get(armChild);
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve("timeout"), timeout);
    timer.unref();
    void readiness.then((status) => {
      clearTimeout(timer);
      resolve(status);
    });
  });
}

function runProcess(command, args, options = {}) {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    proc.on("error", (error) => resolve({ code: 127, stdout, stderr: String(error?.message ?? error) }));
    proc.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
  });
}

async function armReadinessBudgetMs(paths, hostMode) {
  const override = positiveInteger("JG_OPENCODE_ARM_READY_TIMEOUT_MS", 0);
  if (override) return hostMode ? Math.max(override, 30000) : override;
  const result = await runProcess("bash", ["-lc",
    'config_dir="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"; [ ! -f "$config_dir/x-mode.env" ] || . "$config_dir/x-mode.env"; . "$1" && jg_watcher_confirmation_budget "$2" "$3" "$4"',
    "jg-watcher-budget", fileURLToPath(new URL("../../bin/jg-wake-lib.sh", import.meta.url)), paths.state, `${paths.root}/bin/jg-watch.sh`, paths.home,
  ], { env: { ...process.env, JG_HOME: paths.home, JG_CONFIG_OVERRIDE: paths.config, JG_STATE_OVERRIDE: paths.state } });
  const seconds = Number(result.stdout.trim());
  if (result.code !== 0 || !Number.isFinite(seconds) || seconds < 0) return 0;
  const timeout = seconds * 1000 + 2000;
  return hostMode ? Math.max(timeout, 30000) : timeout;
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function effectivePaths(root) {
  const fmRoot = process.env.JG_ROOT_OVERRIDE || root;
  const fmHome = process.env.JG_HOME || process.env.JG_ROOT_OVERRIDE || fmRoot;
  const state = process.env.JG_STATE_OVERRIDE || `${fmHome}/state`;
  const config = process.env.JG_CONFIG_OVERRIDE || `${fmHome}/config`;
  return { root: fmRoot, home: fmHome, state, config };
}

// bin/jg-primary-scope-lib.sh's jg_primary_root_matches is the single owner of
// the primary-home predicate (the turn-end guard and session-start nudge decide
// with the same one), so this plugin can never disagree with them again. It
// force-includes a linked treehouse-leased secondmate home carrying a valid
// .jg-secondmate-home marker, which a bare git-dir==common-dir test rejects.
function isPrimaryRoot(root) {
  if (!root) return false;
  const result = spawnSync(
    "bash",
    ["-c", '. "$1/bin/jg-primary-scope-lib.sh" && jg_primary_root_matches "$1"', "jg-primary-watch-arm", root],
    { stdio: "ignore" },
  );
  return result.status === 0;
}

// bin/jg-supervision-lib.sh's jg_supervision_needed is the single owner of the
// arm condition set (the turn-end guard decides with the same shared
// predicate), so this plugin can never disagree with the guard again. Away
// mode stays a local decline: its daemon owns supervision. X-mode homes arm
// before their relay poll is registered in the state directory.
function shouldArm(paths) {
  if (existsSync(`${paths.state}/.afk`)) return false;
  if (existsSync(`${paths.config}/x-mode.env`)) return true;
  return supervisionNeeded(paths);
}

// jg_supervision_needed <state-dir> exits 0 exactly when the shared predicate
// says the home needs supervision; exit 0 means arm here.
function supervisionNeeded(paths) {
  const result = spawnSync(
    "bash",
    [
      "-c",
      '. "$1/bin/jg-supervision-lib.sh" && jg_supervision_needed "$2"',
      "jg-primary-watch-arm",
      paths.root,
      paths.state,
    ],
    { stdio: "ignore" },
  );
  return result.status === 0;
}

async function sessionOwnsLock(paths) {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${paths.state}/.lock`, "utf8").trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return true;
    const result = await runProcess("ps", ["-o", "ppid=", "-p", pid]);
    if (result.code !== 0) return false;
    pid = result.stdout.trim();
    if (!pid || pid === "1") return false;
  }
  return false;
}

// An away record, never quiet mode's (bin/jg-afk-contract.sh mode owns that
// reading): a record whose mode cannot be read as quiet reads as away.
function awayRecordPresent(paths) {
  if (!existsSync(`${paths.state}/.afk-contract`)) return false;
  const result = spawnSync("bash", [`${paths.root}/bin/jg-afk-contract.sh`, "mode"], {
    encoding: "utf8",
    env: { ...process.env, JG_STATE_OVERRIDE: paths.state },
  });
  return String(result.stdout || "").trim() !== "quiet";
}

// Whether this home runs the supervision host for an OpenCode primary; the
// gate's owner answers, and a query that cannot run reads as no host.
function hostModeEnabled(paths) {
  const result = spawnSync("bash", [`${paths.root}/bin/jg-supervision-engine-lib.sh`, "enabled", paths.config, "opencode"], {
    stdio: "ignore",
  });
  return result.status === 0;
}

// The host-mode wake message: every "supervision-host:" line in order, wake
// lines capped at eight, and the away note while an away record exists.
function hostWakeMessage(paths, combined) {
  let shown = 0;
  const lines = combined.split(/\r?\n/).filter((line) => {
    if (HOST_LINE.test(line)) return true;
    if (WAKE_LINE.test(line) && shown < 8) {
      shown += 1;
      return true;
    }
    return false;
  });
  if (lines.length === 0) return "";
  if (awayRecordPresent(paths)) {
    lines.push("This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.");
  }
  return lines.join("\n");
}

function classifyArmClose(paths, hostMode, stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`;
  if (hostMode) {
    const message = hostWakeMessage(paths, combined);
    if (message) return { kind: "actionable", message };
    const stoodDown = combined.split(/\r?\n/).find((line) => /^supervision-host stood down:/.test(line));
    if (stoodDown) return { kind: "failure", message: `watcher: FAILED - ${stoodDown}` };
  }
  const reason = combined.split(/\r?\n/).find((line) => WAKE_LINE.test(line));
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child ended from ${signal}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  if (code && code !== 0) {
    const script = hostMode ? "jg-supervision-host.sh" : "jg-watch-arm.sh";
    return {
      kind: "failure",
      message: `watcher: FAILED - ${script} exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - OpenCode arm cycle ended without an actionable reason",
  };
}

function observeArmOutput(hostMode, stdout, stderr, settleReadiness) {
  const combined = `${stdout}\n${stderr}`;
  if (combined.split(/\r?\n/).some((line) => WAKE_LINE.test(line) || (hostMode && HOST_LINE.test(line)))) {
    setArmStatus("wake");
    settleReadiness("wake");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: (?:started|attached)\b/.test(line))) {
    setArmStatus("armed");
    settleReadiness("armed");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: healthy\b/.test(line))) {
    setArmStatus("external");
    settleReadiness("external");
    return;
  }
  if (combined.split(/\r?\n/).some((line) => /^watcher: FAILED/.test(line))) {
    setArmStatus("failed");
    settleReadiness("failed");
  }
}

async function sendPrompt(paths, client, sessionID, text) {
  const encoded = await encodeFirstmateOperationalInput(paths.root, "watcher", text);
  await client.session.promptAsync({
    path: { id: sessionID },
    body: {
      parts: [{ type: "text", text: encoded }],
    },
  });
}

function confirmHandlingDelivery(paths, recovery) {
  try {
    const result = spawnSync(
      "bash",
      [`${paths.root}/bin/jg-watch-arm.sh`, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
      {
        cwd: paths.root,
        encoding: "utf8",
        env: { ...process.env, JG_HOME: paths.home, JG_STATE_OVERRIDE: paths.state, JG_ROOT_OVERRIDE: paths.root },
      },
    );
    if (result.status === 0) return { ok: true, detail: "" };
    const stderr = String(result.stderr || "").trim();
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
    };
  } catch (error) {
    return {
      ok: false,
      detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${String(error?.message ?? error)}`,
    };
  }
}

function confirmHandlingDeliveryWithRetry(paths, recovery) {
  const snapshot = () => armRecovery.get(child) ?? recovery;
  const first = confirmHandlingDelivery(paths, snapshot());
  if (first.ok) return first;
  return confirmHandlingDelivery(paths, snapshot());
}

async function deliverActionableWake(paths, client, sessionID, message, recovery) {
  if (recovery) {
    const confirmed = confirmHandlingDeliveryWithRetry(paths, recovery);
    if (!confirmed.ok) {
      if (recovery.watcherPid) {
        try {
          process.kill(Number(recovery.watcherPid), 0);
        } catch {
          await retireArm(child);
        }
      }
      await sendPrompt(paths, client, sessionID, wakePrompt(`${message}\n\n${confirmed.detail}`));
      return;
    }
  }
  await sendPrompt(paths, client, sessionID, wakePrompt(message));
}

function wakePrompt(reason) {
  return `WATCHER FIRED - drain queued wakes with bin/jg-wake-drain.sh and handle the reported wake. Watcher continuity is plugin-owned.\n\n${reason}`;
}

function surfaceFailure(paths, client, sessionID, reason) {
  void sendPrompt(paths, client, sessionID, wakePrompt(reason)).catch(() => {
    // OpenCode owns delivery errors; continuity restoration never waits on prompting.
  });
}

function retryDelay(attempt) {
  return Math.min(REARM_RETRY_MAX_MS, REARM_RETRY_BASE_MS * 2 ** Math.max(0, attempt - 1));
}

function waitForRetry(attempt) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, retryDelay(attempt));
    timer.unref();
  });
}

async function retireArm(armChild) {
  if (!armChild) return true;
  armChild.kill("SIGTERM");
  const closed = armClose.get(armChild);
  if (!closed) return false;
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), ARM_RETIRE_TIMEOUT_MS);
    timer.unref();
    void closed.then(() => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

function restorationFailure(status) {
  if (status === "read-only") {
    return "watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock";
  }
  return `watcher: FAILED - OpenCode could not verify a ready successor watcher (${status || "idle"})`;
}

async function restoreAfterActionableClose(paths, sessionID, client, predecessorArmPid) {
  let failure = "";
  for (let attempt = 0; attempt <= REARM_RETRY_LIMIT; attempt += 1) {
    const { status, armChild } = await ensureArm(paths, sessionID, client, predecessorArmPid, true);
    if (status === "armed") return { failure: "", recovery: armRecovery.get(armChild) };
    // An actionable line belongs to this arm's close handler.
    // Do not retire it before that handler can start the successor cycle.
    if (status === "wake") return { failure: "", recovery: armRecovery.get(armChild) };
    failure = restorationFailure(status);
    if (!(await retireArm(armChild))) {
      setArmStatus("failed");
      return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity because the unready successor arm did not exit within ${ARM_RETIRE_TIMEOUT_MS}ms` };
    }
    if (status === "read-only" || status === "not-primary" || status === "skipped") break;
    if (attempt === REARM_RETRY_LIMIT) break;
    await waitForRetry(attempt + 1);
  }
  setArmStatus("failed");
  return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries` };
}

async function scheduleRetry(paths, sessionID, client, reason, predecessorArmPid) {
  if (child || retryTimer) return;
  if (!(await sessionOwnsLock(paths))) {
    setArmStatus("failed");
    surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode cannot restore continuity because this session no longer owns the lock\n${reason}`);
    return;
  }
  retryFailures += 1;
  if (retryFailures > REARM_RETRY_LIMIT) {
    setArmStatus("failed");
    surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`);
    return;
  }
  setArmStatus("retrying");
  const timer = setTimeout(() => {
    if (retryTimer === timer) retryTimer = null;
    void ensureArm(paths, sessionID, client, predecessorArmPid).then((status) => {
      if (["armed", "starting", "wake"].includes(status)) return;
      surfaceFailure(paths, client, sessionID, `watcher: FAILED - OpenCode could not launch a continuity retry (${status})`);
    });
  }, retryDelay(retryFailures));
  timer.unref();
  retryTimer = timer;
}

function spawnArm(paths, sessionID, client, predecessorArmPid, hostMode, timeoutMs) {
  setArmStatus("starting");
  const env = {
    ...process.env,
    JG_HOME: paths.home,
    JG_ROOT_OVERRIDE: paths.root,
    JG_CONFIG_OVERRIDE: paths.config,
    JG_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
  };
  if (hostMode) env.JG_SUPERVISION_HOST_PRIMARY = "opencode";
  const command = hostMode ? '"$JG_ROOT_OVERRIDE/bin/jg-supervision-host.sh" park --restart' : '"$JG_ROOT_OVERRIDE/bin/jg-watch-arm.sh" --restart';
  const armChild = spawn("bash", ["-lc", `config_dir="\${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec ${command}`], {
    cwd: paths.root,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  armReadyBudget.set(armChild, timeoutMs);
  child = armChild;
  let stdout = "";
  let stderr = "";
  let settled = false;
  let resolveClosed = null;
  let readinessSettled = false;
  let resolveReadiness = null;
  const readiness = new Promise((resolve) => {
    resolveReadiness = resolve;
  });
  armReadiness.set(armChild, readiness);
  const settleReadiness = (status) => {
    if (readinessSettled) return;
    readinessSettled = true;
    resolveReadiness(status);
  };
  const closed = new Promise((resolveClosedChild) => {
    resolveClosed = resolveClosedChild;
  });
  armClose.set(armChild, closed);
  const releaseChild = () => {
    if (child === armChild) child = null;
  };
  const observeRecovery = () => {
    const recovery = `${stdout}\n${stderr}`.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
    if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
  };
  armChild.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    observeRecovery();
    observeArmOutput(hostMode, stdout, stderr, settleReadiness);
  });
  armChild.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
    observeRecovery();
    observeArmOutput(hostMode, stdout, stderr, settleReadiness);
  });
  armChild.on("close", (code, signal) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    const classification = classifyArmClose(paths, hostMode, stdout, stderr, code, signal);
    settleReadiness(classification.kind === "actionable" ? "wake" : "failed");
    const predecessor = String(armChild.pid ?? "");
    if (classification.kind === "actionable") {
      if (restorationInFlight) return;
      retryFailures = 0;
      setArmStatus("wake");
      const restoration = restoreAfterActionableClose(paths, sessionID, client, predecessor);
      restorationInFlight = restoration;
      void restoration.then(async (result) => {
        try {
          const message = result.failure ? `${classification.message}\n\n${result.failure}` : classification.message;
          await deliverActionableWake(paths, client, sessionID, message, result.recovery);
        } finally {
          if (restorationInFlight === restoration) restorationInFlight = null;
        }
      }).catch((error) => {
        if (restorationInFlight === restoration) restorationInFlight = null;
        surfaceFailure(
          paths,
          client,
          sessionID,
          `watcher: FAILED - OpenCode could not deliver an actionable wake\n${String(error?.message ?? error)}`,
        );
      });
      return;
    }
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(paths, sessionID, client, classification.message, predecessor);
  });
  armChild.on("error", (error) => {
    if (settled) return;
    settled = true;
    resolveClosed();
    releaseChild();
    settleReadiness("failed");
    if (restorationInFlight) {
      setArmStatus("failed");
      return;
    }
    void scheduleRetry(
      paths,
      sessionID,
      client,
      `watcher: FAILED - OpenCode arm child failed: ${error.message}`,
      String(armChild.pid ?? ""),
    );
  });
  return armChild;
}

async function beginArm(paths, sessionID, client, predecessorArmPid) {
  if (!sessionID) return { status: "skipped", armChild: null };
  if (!isPrimaryRoot(paths.root)) return { status: "not-primary", armChild: null };
  if (!(await sessionOwnsLock(paths))) return { status: "read-only", armChild: null };
  if (child) return { status: "existing", armChild: child };
  if (retryTimer) return { status: "retrying", armChild: null };
  if (!shouldArm(paths)) return { status: "not-needed", armChild: null };
  const hostMode = hostModeEnabled(paths);
  const timeoutMs = await armReadinessBudgetMs(paths, hostMode);
  if (!timeoutMs) return { status: "failed", armChild: null };
  return { status: "spawned", armChild: spawnArm(paths, sessionID, client, predecessorArmPid, hostMode, timeoutMs) };
}

function armAttempt(status, armChild, includeArmChild) {
  return includeArmChild ? { status, armChild } : status;
}

async function ensureArm(paths, sessionID, client, predecessorArmPid = "", includeArmChild = false) {
  let launchResult = null;
  if (!launchInFlight) {
    const launch = beginArm(paths, sessionID, client, predecessorArmPid);
    launchInFlight = launch;
    try {
      launchResult = await launch;
    } finally {
      if (launchInFlight === launch) launchInFlight = null;
    }
  } else {
    launchResult = await launchInFlight;
  }
  const armChild = launchResult.armChild;
  if (!armChild) {
    return armAttempt(launchResult.status, null, includeArmChild);
  }
  return armAttempt(await waitForArmReady(armChild), armChild, includeArmChild);
}

export const FmPrimaryWatchArm = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const paths = effectivePaths(root);
  globalThis[COORDINATOR_KEY] = {
    ensureArmed: (sessionID, activeClient) => ensureArm(paths, sessionID, activeClient ?? client),
  };

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;
      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;
      void ensureArm(paths, sessionID, client);
    },
  };
};
