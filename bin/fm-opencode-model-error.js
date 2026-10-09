// OpenCode native failure observation; called by the existing busy-state plugin.
// Keep only the error message, never headers, credentials, or request bodies.
import { readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
export function modelErrorObserver(state, id, gen) {
  let session = null;
  let failed = false;
  // A late old process cannot overwrite its replacement's observation.
  const file = `${state}/${id}.model-error-${gen}.json`;
  function save(error) {
    let current;
    try { current = readFileSync(`${state}/${id}.busy-gen`, "utf8").trim(); }
    catch (error) { if (error.code === "ENOENT") return; throw error; }
    if (current !== gen) return;
    const temp = `${file}.${process.pid}.tmp`;
    writeFileSync(temp, JSON.stringify({ gen, error }), { mode: 0o600 });
    renameSync(temp, file);
  }
  if (!existsSync(file)) save("");
  return (event) => {
    const p = event.properties || {};
    if (event.type === "session.status" && p.status?.type === "busy" && session === null) {
      session = p.sessionID;
      failed = false;
      save("");
    }
    if (p.sessionID !== session || session === null) return;
    if (event.type === "session.error" && p.error?.name !== "MessageAbortedError") {
      const error = p.error?.data?.message || p.error?.message || p.error?.name;
      if (error) {
        failed = true;
        save(String(error).slice(0, 1000));
      }
    }
    if (event.type === "session.idle") {
      if (!failed) save("");
      session = null;
    }
  };
}
