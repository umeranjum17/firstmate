// Lead sleep guard, the rule the OpenCode adapter calls. In a squad-lead (secondmate) home a lead that sleeps or polls in the
// foreground cannot see its inbox doorbell, so a bash command that does either is refused with a way forward. Other homes are untouched.
import { lstatSync } from "node:fs";
import { join } from "node:path";

const COMMAND_START = String.raw`(?:^|[;&|(){\n]|\b(?:do|then|else)\b)\s*(?:\w+=\S*\s+)*(?:(?:command|builtin|exec|time|nohup|timeout\s+\S+)\s+)*`;
const FOREGROUND_WAIT = new RegExp(`${COMMAND_START}(?:sleep|watch)\\b`);

const isLeadHome = (dir) => {
	try { const m = lstatSync(join(dir, ".jg-squad-lead-home")); return m.isFile() && !m.isSymbolicLink(); } catch { return false; }
};

// dirs: the session directory and JG_HOME; the home marker in either one makes this a lead home.
export function guard(command, { dirs = [], env = process.env } = {}) {
	if (typeof command !== "string" || !FOREGROUND_WAIT.test(command)) return null;
	if (![...dirs, env.JG_HOME].some((d) => d && isLeadHome(d))) return null;
	return "BLOCKED by the lead sleep guard: a lead must not sleep, watch or poll in the foreground, because it then misses the inbox doorbell. End your turn now and let the watcher wake you when there is something to do.";
}
