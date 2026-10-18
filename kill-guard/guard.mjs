import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

const SELF = realpathSync(fileURLToPath(import.meta.url));
const MODELLED = { kill: "lL", pkill: "f", killall: "" }; // options the guard reads; any other option refuses
const WRAPPERS = /^(sudo|env|nohup|exec|command|builtin|time|nice|ionice|taskset|stdbuf|timeout|setsid|doas|runuser|chrt|flock|unbuffer|xargs|then|do|else|if|elif|case|while|until|\{|[\w.-]+\(\))$/;
const SIGNAL = /^-(\d+|[A-Z][A-Z0-9]*)$/; // -9, -KILL, -SIGTERM
const REDIRECT = /^\d*[<>]|^&>/;
const commandName = (t) => basename(t).replace(/\\/g, "");

// Heredoc bodies are data, except when a shell reads them: drop each body from the line after its marker through the closing word.
function dropHeredocBodies(command) {
	let end = null, shell = false;
	return command.split("\n").filter((line) => {
		if (end !== null) { if (line.trim() === end) end = null; return shell; }
		end = line.match(/(?<!<)<<(?!<)-?\s*(['"]?)([A-Za-z_]\w*)\1/)?.[2] ?? null, shell = /\b(ba|z|da)?sh\b/.test(line);
		return true;
	}).join("\n");
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
	const raw = s.match(/(?:"[^"]*"|'[^']*'|\S)+/g) ?? [];
	const out = [];
	for (let i = 0; i < raw.length; i++) {
		if (!REDIRECT.test(raw[i])) out.push(raw[i]);
		else if (/^(\d*|&)[<>]+&?$/.test(raw[i])) i++;
	}
	return out.map((t) => t.replace(/"([^"]*)"|'([^']*)'/g, "$1$2"));
}

// The command word past assignments and wrappers. xargs means the targets come from stdin.
function commandOf(w) {
	let i = 0, piped = false;
	for (; i < w.length && (/^[A-Za-z_]\w*=|^[-\d.]/.test(w[i]) || WRAPPERS.test(w[i])); i++) piped ||= w[i] === "xargs";
	return { words: w.slice(i), piped };
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

// Why a process may not be signalled, or null when the caller started it.
function reasonFor(p, own) {
	if (p.missing) return `PID ${p.pid} (no such process)`;
	if (p.pid === 1) return "PID 1 (init)";
	if (p.comm === "systemd" && p.argv.includes("--user")) return `PID ${p.pid} (the systemd user manager)`;
	if (p.comm === "herdr" && p.argv.includes("server")) return `PID ${p.pid} (the herdr server)`;
	return own.has(p.pid) ? null : `PID ${p.pid} (${p.comm}), which this task did not start`;
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
	if (!ops.length || (name === "kill" && flags.includes("l"))) return null;
	let hits;
	if (name === "kill") {
		const bad = ops.find((a) => !/^[1-9]\d*$/.test(a));
		if (bad !== undefined) return unresolved(`"${bad}" is not a PID`);
		hits = ops.map((a) => procs().get(+a) ?? { pid: +a, missing: true });
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
	const reason = hits.map((p) => reasonFor(p, own)).find(Boolean);
	return reason ? `"${text}" aims at ${reason}` : null;
}

// Every $( ) and backtick body, nested $( ) included.
function substitutions(text) {
	const out = [];
	for (let i = 0; i < text.length; i++) {
		if (text[i] === "`") {
			const end = text.indexOf("`", i + 1);
			if (end < 0) break;
			out.push(text.slice(i + 1, end));
			i = end;
		} else if (text[i] === "$" && text[i + 1] === "(") {
			let depth = 0, j = i + 1;
			for (; j < text.length; j++) {
				if (text[j] === "(") depth++;
				else if (text[j] === ")" && --depth === 0) break;
			}
			out.push(text.slice(i + 2, j));
			i = j;
		}
	}
	return out;
}

// The first kill, pkill or killall in the command (also inside sh -c, eval, $( ) or backticks) aimed outside the caller's tree.
function blockedBy(command, caller, procs) {
	for (const seg of segments(dropHeredocBodies(command))) {
		const text = seg.trim().replace(/^[\s({!]+/, "");
		const inner = substitutions(text);
		const { words: w, piped } = commandOf(words(text));
		const name = w.length ? commandName(w[0]) : "";
		const shellC = /^(ba|z|da)?sh$/.test(name) ? w.findIndex((t, k) => k > 0 && /^-[a-zA-Z]*c[a-zA-Z]*$/.test(t)) : -1;
		const t = inner.map((c) => blockedBy(c, caller, procs)).find(Boolean) ??
			(shellC >= 0 && w[shellC + 1] ? blockedBy(w[shellC + 1], caller, procs) :
			name === "eval" ? blockedBy(w.slice(1).join(" "), caller, procs) :
			!Object.hasOwn(MODELLED, name) ? null :
			piped ? `"${text}" cannot be resolved to processes: its targets come from xargs` :
			judge(name, w.slice(1), text, caller, procs));
		if (t) return t;
	}
	return null;
}

// Returns the block message, or null to allow. caller is the process whose descendants may be signalled: in-process
// adapters leave it at this process, the Claude hook passes the agent's pid. Unreadable /proc refuses.
export function guard(command, { caller = process.pid } = {}) {
	const text = String(command ?? "");
	let table, target;
	try {
		target = blockedBy(text, caller, () => (table ??= procTable()));
	} catch (e) {
		target = `"${text}" cannot be checked: /proc was unreadable (${e.message})`;
	}
	if (target === null) return null;
	return `BLOCKED by the fleet kill guard: ${target}. Kill only process IDs you started yourself in this task; never PID 1, the systemd user manager, the herdr server, or a process found by name or pattern that you did not start. This block is final: do not retry it, reword it, or work around it. If another process is in your way, write \`blocked:\` naming it and stop.`;
}

// Hook CLI for Claude Code: PreToolUse JSON on stdin; exit 2 with the reason on stderr blocks. --caller is the agent's pid.
if (process.argv[1] && realpathSync(process.argv[1]) === SELF) {
	let p = {};
	try { p = JSON.parse(readFileSync(0, "utf8")); } catch {}
	const i = process.argv.indexOf("--caller");
	const reason = guard(p?.tool_input?.command, { caller: Number(process.argv[i + 1]) || process.ppid });
	if (reason !== null) { process.stderr.write(reason + "\n"); process.exit(2); }
}
