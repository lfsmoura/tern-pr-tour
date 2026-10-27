#!/usr/bin/env bun
// Checks a tour JSON file (references/format.md) against its repository: shape, and that every
// file, line range, mark and hunk it points at exists at the revision it names.
// Usage: bun check-tour.ts FILE.tour.json   → prints problems (exit 1) or a one-line summary.

export {};

type Json = any;

const path = process.argv[2];
if (!path) {
	console.error("usage: bun check-tour.ts FILE.tour.json");
	process.exit(2);
}

const problems: string[] = [];
const fail = (where: string, msg: string) => problems.push(`${where}: ${msg}`);

let tour: Json;
try {
	tour = JSON.parse(await Bun.file(path).text());
} catch (e) {
	console.error(`${path}: ${(e as Error).message}`);
	process.exit(1);
}

function git(args: string[]): { ok: boolean; out: string } {
	const r = Bun.spawnSync(["git", "-C", tour.repo, "-c", "core.quotepath=off", ...args], { stdout: "pipe", stderr: "pipe" });
	return { ok: r.exitCode === 0, out: (r.exitCode === 0 ? r.stdout : r.stderr).toString() };
}

const isStr = (v: unknown): v is string => typeof v === "string" && v.length > 0;
const isLine = (v: unknown): v is number => Number.isInteger(v) && (v as number) >= 1;
const isRange = (v: unknown): v is [number, number] => Array.isArray(v) && v.length === 2 && isLine(v[0]) && isLine(v[1]) && v[0] <= v[1];

// Header -----------------------------------------------------------------------

if (tour?.version !== 1) fail("version", "must be 1");
if (!isStr(tour?.title)) fail("title", "missing");
if (!isStr(tour?.repo) || !tour.repo.startsWith("/")) fail("repo", "must be the absolute path of the checkout");
else if (!git(["rev-parse", "--git-dir"]).ok) fail("repo", `${tour.repo} is not a git checkout`);
for (const side of ["base", "head"] as const) {
	if (!isStr(tour?.[side])) fail(side, "missing");
	else if (problems.length === 0 && !git(["rev-parse", "--verify", "--quiet", `${tour[side]}^{commit}`]).ok)
		fail(side, `${tour[side]} is not a commit in ${tour.repo} (fetch it first)`);
}
if (tour?.agent !== undefined && !Number.isInteger(tour.agent)) fail("agent", "must be the numeric $TERN_PANE");
if (!Array.isArray(tour?.chapters) || tour.chapters.length === 0) fail("chapters", "empty");
if (problems.length) report();

const rev = (at: unknown) => (at === "base" ? tour.base : tour.head);

const fileCache = new Map<string, string[] | null>();
function fileLines(at: unknown, file: string): string[] | null {
	const key = `${rev(at)}:${file}`;
	if (!fileCache.has(key)) {
		const r = git(["show", key]);
		const lines = r.out.split("\n");
		if (lines.at(-1) === "") lines.pop();
		fileCache.set(key, r.ok ? lines : null);
	}
	return fileCache.get(key)!;
}

const changed = new Set(
	git(["diff", "--name-only", "--no-renames", `${tour.base}...${tour.head}`]).out.split("\n").filter(Boolean),
);

// Head-side [first, last] line of each hunk of `git diff base...head -- file`.
const hunkCache = new Map<string, [number, number][]>();
function hunkRanges(file: string): [number, number][] {
	if (!hunkCache.has(file)) {
		const out = git(["diff", "--no-color", "--no-ext-diff", `${tour.base}...${tour.head}`, "--", file]).out;
		const ranges: [number, number][] = [];
		for (const m of out.matchAll(/^@@ -[\d,]+ \+(\d+)(?:,(\d+))? @@/gm)) {
			const start = Number(m[1]);
			ranges.push([start, start + Math.max(Number(m[2] ?? 1) - 1, 0)]);
		}
		hunkCache.set(file, ranges);
	}
	return hunkCache.get(file)!;
}

// Blocks -------------------------------------------------------------------------

const KINDS = ["p", "quote", "list", "pre", "table", "code", "diff", "snippet", "rows", "flow", "timeline", "mermaid", "files", "target"];
const MERMAID = /^\s*(sequenceDiagram|flowchart|graph|stateDiagram(-v2)?|classDiagram|erDiagram|gantt|journey|mindmap|timeline)\b/;
const BASIS = ["fact", "inferred", "opinion"];
const FLOW_KINDS = ["same", "changed", "new", "external"];
const ROLES = ["core", "mechanical", "test", "config", "docs"];
const MARKS = ["ok", "bad", "note"];

function checkBlock(w: string, b: Json) {
	if (typeof b !== "object" || b === null || Array.isArray(b)) return fail(w, "must be an object");
	const kinds = Object.keys(b).filter((k) => KINDS.includes(k));
	const extra = Object.keys(b).filter((k) => !KINDS.includes(k) && !(k === "basis" && "p" in b));
	if (kinds.length !== 1) return fail(w, `needs exactly one of ${KINDS.join(", ")} (has ${Object.keys(b).join(", ") || "none"})`);
	if (extra.length) fail(w, `unknown keys: ${extra.join(", ")}`);
	const kind = kinds[0];
	const v = b[kind];
	switch (kind) {
		case "p":
			if (!isStr(v)) fail(w, "p must be text");
			if (b.basis !== undefined && !BASIS.includes(b.basis)) fail(w, `basis must be ${BASIS.join("|")}`);
			break;
		case "quote":
		case "pre":
			if (!isStr(v)) fail(w, `${kind} must be text`);
			break;
		case "list":
			if (!Array.isArray(v) || !v.every(isStr)) fail(w, "list must be an array of strings");
			break;
		case "table":
			if (!Array.isArray(v?.head) || !Array.isArray(v?.rows)) fail(w, "table needs head and rows");
			else if (v.rows.some((r: Json) => !Array.isArray(r) || r.length !== v.head.length)) fail(w, "every table row needs one cell per head column");
			break;
		case "code":
			return checkCode(w, v);
		case "diff":
			if (!isStr(v?.file)) return fail(w, "diff.file missing");
			if (!changed.has(v.file)) return fail(w, `${v.file} did not change between base and head`);
			if (v.hunks !== undefined && v.lines !== undefined) fail(w, "diff takes hunks or lines, not both");
			if (v.hunks !== undefined) {
				const n = hunkRanges(v.file).length;
				if (!Array.isArray(v.hunks) || v.hunks.some((h: Json) => !Number.isInteger(h) || h < 0 || h >= n))
					fail(w, `hunks must be 0-based indexes below ${n} (${v.file} has ${n} hunks)`);
			}
			if (v.lines !== undefined) {
				if (!isRange(v.lines)) return fail(w, "diff.lines must be [from, to] head lines with 1 ≤ from ≤ to");
				const ranges = hunkRanges(v.file);
				if (!ranges.some(([s, e]) => s <= v.lines[1] && e >= v.lines[0]))
					fail(w, `no hunk touches head lines ${v.lines.join("–")} (hunks cover ${ranges.map((r) => r.join("–")).join(", ")})`);
			}
			break;
		case "mermaid":
			if (!isStr(v) || !MERMAID.test(v)) fail(w, "mermaid must be diagram source starting with its type (sequenceDiagram, flowchart TD, …)");
			break;
		case "snippet":
			if (!isStr(v?.label) || !isStr(v?.text)) fail(w, "snippet needs label and text");
			break;
		case "rows":
			if (!isStr(v?.label) || !Array.isArray(v?.head) || !Array.isArray(v?.data)) fail(w, "rows needs label, head, data");
			else if (v.data.some((r: Json) => !Array.isArray(r) || r.length !== v.head.length)) fail(w, "every rows.data row needs one cell per head column");
			else if (v.added && !v.added.every((a: Json) => v.head.includes(a))) fail(w, "rows.added must name head columns");
			break;
		case "flow":
			if (!Array.isArray(v?.nodes) || v.nodes.length === 0) return fail(w, "flow.nodes empty");
			v.nodes.forEach((n: Json, i: number) => {
				if (!isStr(n?.label)) fail(`${w}.nodes[${i}]`, "label missing");
				if (n?.kind !== undefined && !FLOW_KINDS.includes(n.kind)) fail(`${w}.nodes[${i}]`, `kind must be ${FLOW_KINDS.join("|")}`);
			});
			break;
		case "timeline": {
			const lanes = v?.lanes;
			if (!Array.isArray(lanes) || lanes.length === 0 || lanes.length > 4) return fail(w, "timeline needs 1–4 lanes");
			if (!Array.isArray(v.events) || v.events.length === 0) return fail(w, "timeline.events empty");
			v.events.forEach((e: Json, i: number) => {
				const at = `${w}.events[${i}]`;
				if (!lanes.includes(e?.lane)) fail(at, `lane must be one of ${lanes.join(", ")}`);
				if (e?.to !== undefined && !lanes.includes(e.to)) fail(at, `to must be one of ${lanes.join(", ")}`);
				if (!isStr(e?.text)) fail(at, "text missing");
				if (e?.mark !== undefined && !MARKS.includes(e.mark)) fail(at, `mark must be ${MARKS.join("|")}`);
			});
			break;
		}
		case "files":
			for (const [i, r] of (v?.roles ?? []).entries()) {
				const at = `${w}.roles[${i}]`;
				if (!changed.has(r?.file)) fail(at, `${r?.file} is not a changed file`);
				if (!ROLES.includes(r?.role)) fail(at, `role must be ${ROLES.join("|")}`);
			}
			break;
		case "target":
			if (v !== true) fail(w, "target must be true");
			break;
	}
}

function checkCode(w: string, c: Json) {
	if (!isStr(c?.file)) return fail(w, "code.file missing");
	if (c.at !== undefined && c.at !== "base" && c.at !== "head") return fail(w, "code.at must be base|head");
	const side = c.at === "base" ? "base" : "head";
	const lines = fileLines(c.at, c.file);
	if (!lines) return fail(w, `${c.file} does not exist at ${side} (${rev(c.at)})`);
	if (!isRange(c.lines)) return fail(w, "code.lines must be [from, to] with 1 ≤ from ≤ to");
	const n = lines.length;
	if (c.lines[1] > n) return fail(w, `lines ${c.lines.join("–")} are outside ${c.file} at ${side} (${n} lines)`);
	const show = c.show ?? [Math.max(1, c.lines[0] - 2), Math.min(n, c.lines[1] + 2)];
	if (c.show !== undefined) {
		if (!isRange(c.show)) return fail(w, "code.show must be [from, to] with 1 ≤ from ≤ to");
		if (c.show[1] > n) return fail(w, `show ${c.show.join("–")} is outside ${c.file} at ${side} (${n} lines)`);
		if (c.show[0] > c.lines[0] || c.show[1] < c.lines[1]) fail(w, "show must contain lines");
	}
	for (const [i, m] of (c.marks ?? []).entries()) {
		if (!isLine(m?.line) || m.line < show[0] || m.line > show[1]) fail(`${w}.marks[${i}]`, `line must be inside show ${show[0]}–${show[1]}`);
		if (!isStr(m?.text)) fail(`${w}.marks[${i}]`, "text missing");
	}
}

// Steps --------------------------------------------------------------------------

const flat: { w: string; step: Json }[] = [];
tour.chapters.forEach((ch: Json, ci: number) => {
	if (!isStr(ch?.title)) fail(`chapters[${ci}]`, "title missing");
	if (!Array.isArray(ch?.steps) || ch.steps.length === 0) return fail(`chapters[${ci}]`, "steps empty");
	ch.steps.forEach((step: Json, si: number) => flat.push({ w: `chapters[${ci}].steps[${si}]`, step }));
});

const OPTIONS = 4;
const questions = new Set<string>();

flat.forEach(({ w, step }, i) => {
	if (!isStr(step?.title)) fail(w, "title missing");
	if (!Array.isArray(step?.blocks) || step.blocks.length === 0) return fail(w, "blocks empty");
	step.blocks.forEach((b: Json, bi: number) => checkBlock(`${w}.blocks[${bi}]`, b));
	if (step.question !== undefined && step.question !== true) fail(w, "question must be true or absent");
	if (step.question && (i === flat.length - 1 || flat[i + 1].step?.question)) fail(w, "a question step needs its answer in the next step");
	if (step.fills !== undefined && !(isStr(step.fills) && questions.has(step.fills)))
		fail(w, "fills must be the title of an earlier question step");
	if (step.question) {
		if (questions.has(step.title)) fail(w, "question titles must be unique (answers and fills are keyed by them)");
		questions.add(step.title);
		checkChoices(w, step.choices);
	} else if (step.choices !== undefined) fail(w, "choices only go on a question step");
	if (step.asked !== undefined && !isStr(step.asked)) fail(w, "asked must be the reader's question");
	if (step.asks !== undefined) {
		if (!Array.isArray(step.asks) || step.asks.length > 3 || !step.asks.every(isStr)) fail(w, "asks must be up to 3 strings");
		else if (step.asks.length && (step.question || flat[i + 1]?.step?.question))
			fail(w, "no asks on a question step or the step before it");
	}
});

function checkChoices(w: string, c: Json) {
	if (typeof c !== "object" || c === null) return fail(w, `a question step needs choices: { options: ${OPTIONS} × { text, model? }, answer }`);
	const options = c.options;
	if (!Array.isArray(options) || options.length !== OPTIONS) return fail(`${w}.choices`, `options must be ${OPTIONS} options`);
	if (!Number.isInteger(c.answer) || c.answer < 0 || c.answer >= OPTIONS) return fail(`${w}.choices`, `answer must be the right option's 0-based index (0–${OPTIONS - 1})`);
	const seen = new Set<string>();
	options.forEach((o: Json, oi: number) => {
		const at = `${w}.choices.options[${oi}]`;
		if (!isStr(o?.text)) return fail(at, "text missing");
		if (seen.has(o.text.trim())) fail(at, "options must differ");
		seen.add(o.text.trim());
		if (oi === c.answer) {
			if (o.model !== undefined) fail(at, "the right option has no model");
		} else if (!isStr(o.model)) fail(at, "a wrong option needs model: the wrong understanding that picks it");
	});
}

if (!flat[0]?.step?.blocks?.some((b: Json) => b?.target === true)) fail("chapters[0].steps[0]", "should start with { \"target\": true }");

report();

function report(): never {
	if (problems.length) {
		console.log(problems.join("\n"));
		console.log(`\n${problems.length} problem(s) in ${path}`);
		process.exit(1);
	}
	console.log(`ok: ${flat.length} steps in ${tour.chapters.length} chapters, ${changed.size} changed files`);
	process.exit(0);
}
