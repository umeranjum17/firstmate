// Fleet kill guard, the rule every adapter calls. A kill, pkill or killall may signal only the caller's own descendants,
// never PID 1, the systemd user manager or the herdr server, and never a target it cannot resolve. A reparented target inside the caller's non-home git worktree is also owned. A block is final,
// except a kill whose PID the shell sets ($pid, $!, %1, $(...)): that one asks for the literal PID.
import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { basename, isAbsolute, relative, sep } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const MODELLED = { kill: "lL", pkill: "f", killall: "" }; // options the guard reads; any other option refuses
const WRAPPERS = /^(sudo|env|nohup|exec|command|builtin|time|nice|ionice|taskset|stdbuf|timeout|setsid|doas|runuser|chrt|flock|unbuffer|xargs|then|do|else|if|elif|case|while|until|function|\{)$/;
const KNOWN = /^(kill|pkill|killall|eval|(ba|z|da)?sh)$/;
const SIGNAL = /^-(\d+|[A-Z][A-Z0-9]*)$/; // -9, -KILL, -SIGTERM
const REDIRECT = /^\d*[<>]|^&>/;
const commandName = (t) => basename(t).replace(/\\/g, "");

// Heredoc bodies are data, except when a shell reads them: drop each body from the line after its marker through the closing word.
// An unquoted marker still runs the body's $( ) and backticks, so those come back as runs.
const bare = (line) => line.replace(/\(\(.*?\)\)/g, "").replace(/(?<!<<-?\s*)"[^"]*"|(?<!<<-?\s*)'[^']*'/g, "''");
function dropHeredocBodies(command) {
	let end = null, shell = false, quoted = false, body = [];
	const runs = [], rest = command.split("\n").filter((line) => {
		if (end === null) {
			const m = bare(line).match(/(?<!<)<<(?!<)-?\s*(['"]?)([A-Za-z_]\w*)\1/);
			end = m?.[2] ?? null, quoted = !!m?.[1], shell = /(^|[\s;&|(`])(\S*\/)?(ba|z|da)?sh(?=[\s<;&|)]|$)/.test(bare(line));
			return true;
		}
		if (line.trim() !== end) { if (!shell) body.push(line); return shell; }
		if (!quoted) runs.push(...substitutions(body.join("\n"), true));
		end = null, body = [];
		return shell;
	});
	return { rest: rest.join("\n"), runs };
}

// Simple commands, split on ; | & and newlines outside quotes.
function segments(command) {
	const out = [""];
	for (let i = 0, q = ""; i < command.length; i++) {
		const c = command[i];
		if (!q && (";|\n".includes(c) || (c === "&" && !/[<>]/.test(command[i - 1] ?? "") && command[i + 1] !== ">"))) out.push("");
		else if (c === "\\" && q !== "'") out[out.length - 1] += c + (command[++i] ?? "");
		else {
			if (c === q) q = "";
			else if (!q && (c === '"' || c === "'")) q = c;
			out[out.length - 1] += c;
		}
	}
	return out;
}

// The words of a simple command with its redirections dropped: `kill 4242 2>/dev/null` has one operand.
function words(s) {
	const raw = s.match(/\d*[<>]+&?|&>|(?:"[^"]*"|'[^']*'|\$\((?:[^()]|\([^()]*\))*\)|`[^`]*`|[^\s<>])+/g) ?? [];
	const out = [];
	for (let i = 0; i < raw.length; i++) {
		if (!REDIRECT.test(raw[i])) out.push(raw[i]);
		else if (/^(\d*|&)[<>]+&?$/.test(raw[i])) i++;
	}
	return out.map((t) => t.replace(/"([^"]*)"|'([^']*)'/g, "$1$2"));
}

// The command word past assignments and wrappers. xargs means the targets come from stdin.
function commandOf(w) {
	let i = 0, piped = false, wrapped = false; const split = [];
	for (; i < w.length; i++) {
		const skip = /^[A-Za-z_]\w*=|^[-\d]/.test(w[i]) || WRAPPERS.test(w[i]);
		if (!skip && (!wrapped || KNOWN.test(commandName(w[i])))) break;
		if (wrapped && /\s/.test(w[i])) split.push(w[i].replace(/^(-S|--split-string=)/, ""));
		piped ||= w[i] === "xargs"; wrapped ||= WRAPPERS.test(w[i]);
	}
	return { words: w.slice(i), piped, split };
}

// Every process from /proc. Throws when /proc cannot be read.
function procTable() {
	const table = new Map();
	for (const d of readdirSync("/proc").filter((d) => /^\d+$/.test(d))) {
		try {
			const stat = readFileSync(`/proc/${d}/stat`, "utf8");
			const ppid = +stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1];
			table.set(+d, { pid: +d, ppid, comm: readFileSync(`/proc/${d}/comm`, "utf8").trim(), argv: readFileSync(`/proc/${d}/cmdline`, "utf8").split("\0").filter(Boolean) });
		} catch (e) { if (existsSync(`/proc/${d}`)) throw e; } // exited while listed
	}
	return table;
}

function inCallerWorktree(target, caller) {
	try {
		const cwd = realpathSync(`/proc/${caller}/cwd`);
		const root = realpathSync(execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim());
		const home = realpathSync(process.env.HOME);
		const under = (parent, path) => { const rel = relative(parent, path); return rel === "" || (!rel.startsWith(`..${sep}`) && rel !== ".." && !isAbsolute(rel)); };
		if (cwd !== root || root === "/" || root === "/tmp" || under(root, home) ||
			(existsSync(`${root}/state`) && existsSync(`${root}/data`) && existsSync(`${root}/bin/fm-spawn.sh`))) return false;
		const rel = relative(root, target);
		return rel === "" || (!rel.startsWith(`..${sep}`) && rel !== ".." && !isAbsolute(rel));
	} catch { return false; }
}

// Why a process may not be signalled, or null when the caller started it.
function reasonFor(p, own, caller) {
	if (p.missing) return `PID ${p.pid} (no such process)`;
	if (p.pid === 1) return "PID 1 (init)";
	if (p.comm === "systemd" && p.argv.includes("--user")) return `PID ${p.pid} (the systemd user manager)`;
	if (p.comm === "herdr" && p.argv.includes("server")) return `PID ${p.pid} (the herdr server)`;
	let cwd;
	try { cwd = realpathSync(`/proc/${p.pid}/cwd`); } catch { return `PID ${p.pid} (${p.comm}), whose cwd cannot be read`; }
	return own.has(p.pid) || inCallerWorktree(cwd, caller) ? null : `PID ${p.pid} (${p.comm}), which this task did not start`;
}

// The block for one kill, pkill or killall, or null when every process it would signal is the caller's own.
function judge(name, args, text, caller, procs) {
	const flags = [], ops = [];
	let signalled = false;
	for (let i = 0; i < args.length; i++) {
		const a = args[i];
		if (a === "--") { ops.push(...args.slice(i + 1)); break; }
		if (name === "kill" && (a === "-s" || a === "-n")) { i++; signalled = true; }
		else if (!signalled && !ops.length && SIGNAL.test(a)) signalled = true;
		else if (/^-[a-zA-Z]+$/.test(a)) flags.push(...a.slice(1));
		else ops.push(a);
	}
	const unresolved = (why) => `"${text}" cannot be resolved to processes: ${why}`;
	if (flags.some((f) => !MODELLED[name].includes(f))) return unresolved("an option the guard does not read");
	if (!ops.length) return null;
	let hits, shellSet;
	if (name === "kill") {
		const pid = (a) => /^[1-9]\d*$/.test(a), fromShell = (a) => /[$`]|^%/.test(a); // $pid, $!, $(...), %1
		const bad = ops.find((a) => !pid(a) && !fromShell(a));
		if (bad !== undefined) return unresolved(`"${bad}" is not a PID`);
		shellSet = ops.find(fromShell);
		hits = ops.filter(pid).map((a) => procs().get(+a) ?? { pid: +a, missing: true });
	} else {
		if (ops.some((o) => /[$`]/.test(o))) return unresolved("the pattern is set by the shell");
		if (name === "killall" && ops.some((o) => o.includes("/"))) return unresolved("a name with a slash selects processes by executable path");
		let test = (p) => ops.includes(p.comm) || ops.includes(basename(p.argv[0] ?? ""));
		if (name === "pkill") {
			if (/[\\[{]/.test(ops[0])) return unresolved("the pattern uses regex syntax that pkill and JavaScript read differently");
			let re;
			try { re = new RegExp(ops[0]); } catch { return unresolved("the pattern is not a regex"); }
			test = (p) => re.test(flags.includes("f") ? p.argv.join(" ") : p.comm);
		}
		hits = [...procs().values()].filter(test);
	}
	const kids = new Map();
	for (const p of procs().values()) kids.set(p.ppid, [...(kids.get(p.ppid) ?? []), p.pid]);
	const own = new Set(), todo = [caller];
	while (todo.length) for (const c of kids.get(todo.pop()) ?? []) if (!own.has(c)) { own.add(c); todo.push(c); }
	const reason = hits.map((p) => reasonFor(p, own, caller)).find(Boolean);
	if (reason) return `"${text}" aims at ${reason}`;
	return shellSet === undefined ? null : { retry: `"${text}": the shell sets its target (${shellSet})` };
}

// Index of the ) closing the $( opened at open, skipping quoted and escaped text.
function closeOf(text, open) {
	let depth = 0, q = "";
	for (let j = open; j < text.length; j++) {
		const c = text[j];
		if (q === "'") { if (c === "'") q = ""; }
		else if (c === "\\") j++;
		else if (c === '"') q = q ? "" : '"';
		else if (c === "'" && !q) q = "'";
		else if (!q && c === "(") depth++;
		else if (!q && c === ")" && --depth === 0) return j;
	}
	return text.length;
}

// Every $( ), <( ), >( ) and backtick body that the shell runs, nested $( ) included; single-quoted text is data.
// In a heredoc body (literal) quotes are plain characters.
function substitutions(text, literal = false) {
	const out = [];
	for (let i = 0, q = ""; i < text.length; i++) {
		const c = text[i];
		if (q === "'") { if (c === "'") q = ""; }
		else if (c === "\\") i++;
		else if (c === '"' && !literal) q = q ? "" : '"';
		else if (c === "'" && !q && !literal) q = "'";
		else if (c === "`") {
			const end = text.indexOf("`", i + 1);
			if (end < 0) break;
			out.push(text.slice(i + 1, end));
			i = end;
		} else if ((c === "$" || (!q && (c === "<" || c === ">"))) && text[i + 1] === "(") {
			const end = closeOf(text, i + 1);
			out.push(text.slice(i + 2, end));
			i = end;
		}
	}
	return out;
}

// The first kill, pkill or killall in the command (also inside sh -c, eval, $( ) or backticks) aimed outside the caller's tree.
// A final block anywhere beats a retry, so "kill $p; kill 1" is refused for good.
const worst = (ts) => ts.find((t) => t && !t.retry) ?? ts.find(Boolean) ?? null;
function blockedBy(command, caller, procs) {
	const { rest, runs } = dropHeredocBodies(command);
	return worst([...runs.map((c) => blockedBy(c, caller, procs)), ...segments(rest).map((seg) => {
		const text = seg.trim().replace(/^[\s({!]+/, "").replace(/^[\w.-]+\s*\(\s*\)\s*/, "");
		const { words: w, piped, split } = commandOf(words(text));
		const name = w.length ? commandName(w[0]) : "";
		const shellC = /^(ba|z|da)?sh$/.test(name) ? w.findIndex((t, k) => k > 0 && /^-[a-zA-Z]*c[a-zA-Z]*$/.test(t)) : -1;
		return worst([...substitutions(text).map((c) => blockedBy(c, caller, procs)), ...split.map((s) => blockedBy(s, caller, procs)),
			shellC >= 0 && w[shellC + 1] ? blockedBy(w[shellC + 1], caller, procs) :
			name === "eval" ? blockedBy(w.slice(1).join(" "), caller, procs) :
			!Object.hasOwn(MODELLED, name) ? null :
			piped ? `"${text}" cannot be resolved to processes: its targets come from xargs` :
			judge(name, w.slice(1), text, caller, procs)]);
	})]);
}

// Returns the block message, or null to allow. caller is the process whose descendants may be signalled: in-process
// adapters leave it at this process, the Claude hook passes the agent's pid. Unreadable /proc refuses.
export function guard(command, { caller = process.pid } = {}) {
	let table, target;
	try {
		target = typeof command === "string" ? blockedBy(command, caller, () => (table ??= procTable())) : "no command string was given";
	} catch (e) {
		target = `"${command}" cannot be checked: /proc was unreadable (${e.message})`;
	}
	if (target === null) return null;
	if (target.retry) return `The fleet kill guard cannot check ${target.retry}. This is not a final block: print the PID (echo it, or jobs -l for a job number), then run kill again with the literal number; the guard allows it when this task started that process.`;
	return `BLOCKED by the fleet kill guard: ${target}. Kill only process IDs you started yourself in this task; never PID 1, the systemd user manager, the herdr server, or a process found by name or pattern that you did not start. This block is final: do not retry it, reword it, or work around it. If another process is in your way, write \`blocked:\` naming it and stop.`;
}

// Hook CLI for Claude Code: PreToolUse JSON on stdin; exit 2 with the reason on stderr blocks. --caller is the agent's pid.
// argv[1] may name no file on disk: the compiled pi binary's is /$bunfs/root/pi, which its own existsSync still reports.
let entry = null;
try { entry = realpathSync(process.argv[1]); } catch {}
if (entry === realpathSync(fileURLToPath(import.meta.url))) {
	let command;
	try { command = JSON.parse(readFileSync(0, "utf8"))?.tool_input?.command; } catch {}
	const i = process.argv.indexOf("--caller");
	const reason = guard(command, { caller: Number(process.argv[i + 1]) || process.ppid });
	if (reason !== null) { process.stderr.write(reason + "\n"); process.exit(2); }
}
