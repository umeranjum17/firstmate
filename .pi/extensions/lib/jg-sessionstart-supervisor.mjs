import { spawn } from "node:child_process";
// jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves here
for (const [_jgOld, _jgVal] of Object.entries(process.env))
  if (_jgOld.startsWith("FM_") && process.env[`JG_${_jgOld.slice(3)}`] === undefined)
    process.env[`JG_${_jgOld.slice(3)}`] = _jgVal;

const [runner, ...args] = process.argv.slice(2);
let runnerCode;
let outputBytes = 0;
let pendingWrites = 0;
let resultSent = false;

const sendResult = () => {
  if (resultSent || runnerCode === undefined || pendingWrites !== 0) return;
  resultSent = true;
  process.send?.({ type: "result", code: runnerCode, bytes: outputBytes });
};

process.on("SIGTERM", () => {});
process.on("disconnect", () => {
  try {
    process.kill(-process.pid, "SIGKILL");
  } catch {
    process.exit(1);
  }
});

const child = spawn(runner, args, {
  env: { ...process.env, JG_SESSIONSTART_SUPERVISOR_PID: String(process.pid) },
  stdio: ["ignore", "pipe", "ignore"],
});
child.stdout.on("data", (chunk) => {
  outputBytes += chunk.length;
  pendingWrites += 1;
  process.stdout.write(chunk, () => {
    pendingWrites -= 1;
    sendResult();
  });
});
child.on("error", () => {
  runnerCode = null;
  sendResult();
});
child.on("close", (code) => {
  runnerCode = code;
  sendResult();
});
