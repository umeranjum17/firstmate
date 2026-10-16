// Fleet delete guard: the one rule every runtime adapter calls (pi, opencode, and this file's CLI for the Claude hook).
// A block is final: no allow-once, flag or env override. Each block appends one JSON line to <home>/state/delete-guard.log
// for the delete-guard check; a repeat by the same task within REPEAT_SECS also queues an immediate wake for that home.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir, userInfo } from "node:os";
import { dirname, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SELF = fileURLToPath(import.meta.url);
const HOMES = [...new Set([userInfo().homedir, homedir()].map((h) => h.replace(/\/+$/, "")))];
const REPEAT_SECS = 600;
const BARE_VAR = /^(\$\w+|\$\{[^}]+\})(\/+(\.?\*|\.)?)?$/; // $X, ${X:-y}, $X/, $X/*, $X/.
const SHELL_VARS = /^(HOME|PWD|OLDPWD|TMPDIR|TMP|TEMP|USER|LOGNAME|SHELL|PATH|IFS|BASH\w*|(XDG|FM|CLAUDE|CODEX|HERDR|PI|OPENCODE|NO_MISTAKES)_\w*)$/;

function words(segment) {
	return (segment.match(/(?:"[^"]*"|'[^']*'|[^\s"'])+/g) ?? []).map((t) => t.replace(/"([^"]*)"|'([^']*)'/g, "$1$2"));
}

// The one bare-variable exception: the last assignment to it before the delete, in the same command, is its own statement
// d=$(mktemp) or d=$(mktemp -d), and it is not a variable the shell or runtime sets. The target must be exactly "$d" or "${d}".
function freshTempVar(arg, segments, at) {
	const name = (arg.match(/^\$(\w+)$|^\$\{(\w+)\}$/) ?? []).slice(1).find(Boolean);
	if (!name || SHELL_VARS.test(name)) return false;
	const assigns = new RegExp(`(^|[\\s;({])(export\\s+|local\\s+|readonly\\s+|typeset\\s+|declare(\\s+-\\w+)*\\s+)?${name}\\+?=|\\$\\{${name}:?=|\\b(read|for|unset|mapfile|readarray|printf\\s+-v)\\b.*\\b${name}\\b`);
	let fresh = false;
	for (let j = 0; j <= at; j++) {
		if (!assigns.test(segments[j])) continue;
		fresh = j < at && new RegExp(`^${name}=("?)\\$\\(mktemp( -d)?\\)\\1$`).test(segments[j].trim());
	}
	return fresh;
}

function dangerousTarget(arg, segments, at) {
	if (!arg || arg === "--") return false;
	if (BARE_VAR.test(arg)) return !freshTempVar(arg, segments, at); // otherwise blocked whatever the variable holds
	if (arg.includes("$") && /(^|\/)\.\.(\/|$)/.test(arg)) return true; // $d/.. and $d/../x
	let a = arg.replace(/^(\$HOME|\$\{HOME\}|~)(?=\/|$)/, HOMES[0]);
	a = posix.normalize(a.replace(/\/\.?\*$/, "")).replace(/\/+$/, "") || "/";
	if (/^(\.\.?|(\.\.\/)*\.\.)$/.test(a) || a === "*" || a === ".*") return true;
	if (a === "/" || a === "/home" || /^\/home\/[^/]+$/.test(a)) return true;
	return HOMES.some((h) => a === h || (a.startsWith(h + "/") && !a.slice(h.length + 1).includes("/")));
}

// Simple commands, split on ; | & and newlines outside quotes. A heredoc body fed to a shell stays commands; any other is data.
function segmentsOf(command) {
	const text = command.replace(/([^\n]*?)<<-?\s*(['"]?)(\w+)\2([^\n]*)\n([\s\S]*?)\n[ \t]*\3[ \t]*(?=\n|$)/g, (m, pre, q, tag, rest, body) =>
		/(^|[\s;&|(/])(ba|z|da)?sh(\s|$)/.test(pre + rest) ? `${pre}${rest}\n${body}` : pre + rest);
	const out = [""];
	for (let i = 0, q = ""; i < text.length; i++) {
		const c = text[i];
		if (!q && ";|&\n".includes(c)) { out.push(""); continue; }
		if (c === "\\" && q !== "'") out[out.length - 1] += c + (text[++i] ?? "");
		else out[out.length - 1] += c;
		if (c === q) q = "";
		else if (!q && (c === '"' || c === "'")) q = c;
	}
	return out;
}

export function blockedDelete(command) {
	const segments = segmentsOf(command);
	for (const [at, segment] of segments.entries()) {
		const w = words(segment.trim());
		const shell = w.findIndex((t, i) => /(^|\/)(ba|z|da)?sh$/.test(t) && w[i + 1] === "-c");
		if (shell >= 0 && w[shell + 2]) {
			const inner = blockedDelete(w[shell + 2]);
			if (inner !== null) return inner;
		}
		const i = w.findIndex((t) => /(^|\/|\\)(rm|rimraf)$/.test(t));
		const f = w.findIndex((t) => /(^|\/)find$/.test(t));
		const isFind = f >= 0 && w.includes("-delete");
		if (i < 0 && !isFind) continue;
		let args = i >= 0 ? w.slice(i + 1) : w.slice(f + 1);
		if (i < 0) args = args.slice(0, Math.max(0, args.findIndex((t) => /^[-(!]/.test(t)))); // find start paths
		const recursive = i < 0 || /rimraf$/.test(w[i]) || args.some((t) => /^-[a-zA-Z]*[rR]/.test(t) || t === "--recursive");
		if (!recursive) continue;
		const target = args.find((t) => (!t.startsWith("-") || i < 0) && dangerousTarget(t, segments, at));
		if (target !== undefined) return target;
	}
	return null;
}

function escalate(row) {
	let home = "";
	try { home = readFileSync(`${dirname(SELF)}/home`, "utf8").trim(); } catch {}
	if (!home) return;
	const log = `${home}/state/delete-guard.log`, key = row.task || row.cwd, since = Date.parse(row.at) - REPEAT_SECS * 1000;
	appendFileSync(log, JSON.stringify(row) + "\n");
	const recent = readFileSync(log, "utf8").split("\n").filter((l) => {
		try { const r = JSON.parse(l); return (r.task || r.cwd) === key && Date.parse(r.at) >= since; } catch { return false; }
	});
	if (recent.length < 2) return;
	const reason = `check: delete guard REPEAT: ${row.task ? "task " + row.task : "an agent in " + row.cwd} tried ${recent.length} blocked recursive deletes in ${REPEAT_SECS / 60} min (home ${row.home || "?"}, ${row.runtime}); latest: ${row.command.slice(0, 200)} - stop that task and check it`;
	const wake = spawnSync("bash", ["-c", '. "$1/bin/fm-wake-lib.sh" && fm_wake_append check delete-guard "$2"', "_", home, reason],
		{ env: { PATH: process.env.PATH, FM_HOME: home }, stdio: ["ignore", "ignore", "pipe"] });
	if (wake.status !== 0) throw new Error(`repeat wake failed: ${wake.stderr}`);
}

// Returns the block message, or null to allow. Logging and waking never turn a block into an allow.
export function guard(command, { cwd = process.cwd(), runtime = "unknown" } = {}) {
	const target = blockedDelete(String(command ?? ""));
	if (target === null) return null;
	const env = process.env;
	// The true home: the task's inbox, else the firstmate home holding cwd (a lead or Main may inherit another FM_HOME), else FM_HOME.
	let home = env.FM_TASK_INBOX ? dirname(dirname(env.FM_TASK_INBOX)) : "";
	for (let d = resolve(cwd); !home && d !== "/"; d = dirname(d)) if (existsSync(`${d}/bin/fm-wake-lib.sh`) && existsSync(`${d}/state`)) home = d;
	const row = { at: new Date().toISOString(), home: home || env.FM_HOME || "", task: env.FM_TASK_ID || "", cwd, runtime, target, command: String(command).slice(0, 600) };
	let note = "";
	try { escalate(row); } catch (e) { note = ` (the block could not be logged: ${e.message})`; }
	return (
		`BLOCKED by the fleet delete guard: a recursive delete aimed at "${target}" (/, /home, a home folder or a folder directly in it, a bare . .. * ` +
		`or a $VAR target; only a d=$(mktemp -d) made in the same command may be deleted as "$d"). This block is final and has been reported to your ` +
		`supervisor: do not retry it or work around it. If you truly need this delete, stop and report it as blocked.${note}`
	);
}

// Hook CLI for Claude Code: PreToolUse JSON on stdin; exit 2 with the reason on stderr blocks (stdout stays empty for Claude).
if (process.argv[1] === SELF) {
	let p = {};
	try { p = JSON.parse(readFileSync(0, "utf8")); } catch {}
	const r = process.argv.indexOf("--runtime");
	const reason = guard(p?.tool_input?.command, { cwd: p?.cwd || process.cwd(), runtime: (r > 1 && process.argv[r + 1]) || "unknown" });
	if (reason !== null) { process.stderr.write(reason + "\n"); process.exit(2); }
}
