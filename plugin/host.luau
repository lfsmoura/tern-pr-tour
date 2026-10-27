--!strict
-- The host half: the `tour` block. It reads a tour JSON file (written by an
-- agent following the pr-tour skill) and shows it one step at a time. Code,
-- diffs, file stats and commits come from git at the tour's base/head, never
-- from the JSON, so what the reader sees is the real code.
--
-- The block polls its file, so an agent that inserts answer steps (after a
-- `?` question) or fixes a step sees the change land without a reopen.

local ui = tern.ui

local POLL_MS = 1000
local LINK = "tern-difftour://"

type Step = {
	title: string,
	question: boolean?,
	-- Four options the reader must pick from (or "I don't know") before going on.
	choices: any?,
	-- On steps written after a missed question: that question's title.
	fills: string?,
	asked: string?,
	asks: { string }?,
	blocks: { any },
}
-- `n`: the step's 1-based index in the file; nil on a `regen` placeholder, which stands
-- where the steps filling the gap of the missed question named by `regen` will land.
type Flat = { chapter: string, ci: number, si: number, n: number?, regen: string?, step: Step }
type Git = { pending: boolean, ok: boolean, text: string }
type State = {
	cx: BlockCx,
	path: string,
	raw: string?,
	tour: any,
	steps: { Flat },
	-- Steps in the file (`steps` also holds regen placeholders).
	count: number,
	at: number,
	-- Picks by question title: the option's 0-based index in the file, -1 for "I don't know".
	answers: { [string]: number },
	problem: string?,
	repo: string?,
	-- Whether the repo's HEAD is the tour's head (nil until git answers).
	checkout: boolean?,
	-- A follow/`o` open that waits for git; its value is whether to focus.
	reopen: boolean?,
	git: { [string]: Git },
	follow: boolean,
	toc: boolean,
	pending_ask: number?,
	poll: TimerHandle?,
}

local running: { [number]: State } = {}

local function first_line(text: string): string
	return string.match(text, "[^\n]+") or text
end

local function url_encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function dirname(p: string): string
	return string.match(p, "^(.*)/[^/]*$") or "."
end

local function split_lines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n?") do
		table.insert(out, line)
	end
	-- gmatch yields a trailing empty match after the last newline.
	if out[#out] == "" then
		table.remove(out)
	end
	return out
end

local LANGS: { [string]: string } = {
	ts = "typescript", tsx = "tsx", mts = "typescript", cts = "typescript",
	js = "javascript", jsx = "jsx", mjs = "javascript", cjs = "javascript",
	py = "python", go = "go", rs = "rust", rb = "ruby", lua = "lua", luau = "lua",
	sql = "sql", sh = "bash", bash = "bash", zsh = "bash", json = "json", yaml = "yaml",
	yml = "yaml", toml = "toml", md = "markdown", css = "css", scss = "scss", html = "html",
	java = "java", kt = "kotlin", swift = "swift", c = "c", h = "c", cpp = "cpp", cs = "csharp",
	php = "php", ex = "elixir", exs = "elixir", graphql = "graphql", prisma = "prisma",
}

local function lang_of(file: string): string?
	local ext = string.match(file, "%.([%w]+)$")
	return if ext then LANGS[string.lower(ext)] else nil
end

-- Lifecycle --------------------------------------------------------------

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
		tern.kv.set("pane:" .. state.cx.pane, nil)
	end
	if state.poll then
		state.poll:cancel()
		state.poll = nil
	end
end

-- Blocks have no close hook: a restarted pane reuses its id, a closed one leaves the list.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

local function render(state: State)
	if alive(state) then
		state.cx:render()
	end
end

-- Git --------------------------------------------------------------------

-- Set below: opens a deferred location once the git read it waited on lands.
local retry_open: (State) -> ()

-- Runs git once per key; `view` reads the cache and shows a placeholder until it fills.
local function git(state: State, key: string, args: { string })
	if state.git[key] or not state.repo then
		return
	end
	state.git[key] = { pending = true, ok = false, text = "" }
	local argv = { "git", "-C", state.repo :: string, "-c", "core.quotepath=off" }
	for _, a in args do
		table.insert(argv, a)
	end
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = 20000 }, function(r: ProcessResult, _)
			state.git[key] = {
				pending = false,
				ok = r.status == 0,
				text = if r.status == 0 then r.stdout else first_line(r.stderr),
			}
			retry_open(state)
			render(state)
		end)
	end)
	if not ok then
		state.git[key] = { pending = false, ok = false, text = tostring(err) }
	end
end

local function rev(state: State, at: string?): string
	return if at == "base" then state.tour.base else state.tour.head
end

local function show_key(state: State, at: string?, file: string): string
	return "show:" .. rev(state, at) .. ":" .. file
end

local function want_show(state: State, at: string?, file: string)
	git(state, show_key(state, at, file), { "show", rev(state, at) .. ":" .. file })
end

local function range(state: State): string
	return state.tour.base .. "..." .. state.tour.head
end

local function want_diff(state: State, file: string)
	git(state, "diff:" .. file, { "diff", "--no-color", "--no-ext-diff", range(state), "--", file })
end

-- Starts the git reads the current step (and the next, so → is instant) needs.
local function prefetch(state: State)
	for i = state.at, math.min(state.at + 1, #state.steps) do
		for _, b in state.steps[i].step.blocks or {} do
			if type(b) ~= "table" then
				continue
			end
			if type(b.code) == "table" and type(b.code.file) == "string" then
				want_show(state, b.code.at, b.code.file)
			elseif type(b.diff) == "table" and type(b.diff.file) == "string" then
				want_diff(state, b.diff.file)
			elseif type(b.files) == "table" then
				git(state, "numstat", { "diff", "--numstat", "--no-renames", range(state) })
			elseif b.target then
				git(state, "log", { "log", "--reverse", "--format=%h%x09%s", state.tour.base .. ".." .. state.tour.head })
				git(state, "shortstat", { "diff", "--shortstat", range(state) })
			end
		end
	end
end

-- Hunks of a unified diff, without the `diff --git`/`---`/`+++` header.
local function hunks_of(text: string): { string }
	local hunks: { { string } } = {}
	for _, line in split_lines(text) do
		if string.sub(line, 1, 2) == "@@" then
			table.insert(hunks, { line })
		elseif #hunks > 0 then
			table.insert(hunks[#hunks], line)
		end
	end
	local out: { string } = {}
	for _, h in hunks do
		table.insert(out, table.concat(h, "\n"))
	end
	return out
end

-- Opening code beside the tour ---------------------------------------------

-- The first place a step points at: { file, at, line }.
local function location(step: Step): (string?, string?, number?)
	for _, b in step.blocks or {} do
		if type(b) ~= "table" then
			continue
		end
		if type(b.code) == "table" and type(b.code.file) == "string" then
			local lines = b.code.lines
			return b.code.file, b.code.at, if type(lines) == "table" then tonumber(lines[1]) else nil
		elseif type(b.diff) == "table" and type(b.diff.file) == "string" then
			local lines = b.diff.lines
			return b.diff.file, "head", if type(lines) == "table" then tonumber(lines[1]) else nil
		end
	end
	return nil, nil, nil
end

-- The worktree file when the checkout is at head, else a snapshot of the file at
-- that revision in the plugin data dir (so base code and unchecked-out PRs open too).
local function open_location(state: State, file: string, at: string?, line: number?, focus: boolean): boolean
	local repo = state.repo
	if not repo or state.checkout == nil then
		return false
	end
	local function go(path: string, l: number?)
		local url = LINK .. "show?pane=" .. state.cx.pane .. "&path=" .. url_encode(path) .. (if l then "&line=" .. l else "")
		if focus then
			url ..= "&focus=1"
		end
		state.cx:open(url)
	end
	if at ~= "base" and state.checkout then
		go(repo .. "/" .. file, line)
		return true
	end
	local g = state.git[show_key(state, at, file)]
	if not g or g.pending then
		want_show(state, at, file)
		return false
	elseif not g.ok then
		-- Nothing to open; the code card shows why.
		return true
	end
	local path = tern.plugin.data .. "/snapshots/" .. string.sub(rev(state, at), 1, 12) .. "/" .. file
	if not tern.fs.exists(path) then
		tern.fs.mkdir(dirname(path))
		tern.fs.write(path, g.text)
	end
	go(path, line)
	return true
end

local function diff_line(state: State, file: string): number?
	local g = state.git["diff:" .. file]
	if g and g.ok then
		local start = string.match(g.text, "\n@@ %-%d+,?%d* %+(%d+)")
		return tonumber(start)
	end
	return nil
end

local function open_step(state: State, focus: boolean)
	local flat = state.steps[state.at]
	if not flat then
		return
	end
	local file, at, line = location(flat.step)
	if file and not open_location(state, file, at, line or diff_line(state, file), focus) then
		state.reopen = focus
	end
end

retry_open = function(state: State)
	local focus = state.reopen
	if focus ~= nil then
		state.reopen = nil
		open_step(state, focus)
	end
end

-- Loading ------------------------------------------------------------------

local function flatten(tour: any): { Flat }
	local out: { Flat } = {}
	for ci, ch in tour.chapters or {} do
		for si, step in ch.steps or {} do
			table.insert(out, { chapter = ch.title or "", ci = ci, si = si, n = #out + 1, step = step })
		end
	end
	return out
end

-- A question's choices, when it has well-formed ones.
local function choices_of(step: Step): any?
	local c = if step.question then step.choices else nil
	if type(c) == "table" and type(c.options) == "table" and #c.options >= 2 and type(c.answer) == "number" then
		return c
	end
	return nil
end

local function option_text(c: any, i: number): string
	local o = c.options[i + 1]
	return if type(o) == "table" then tostring(o.text or "") else tostring(o or "")
end

-- The order options show in (0-based file indexes), shuffled per question so the right
-- one is not always where the author wrote it, and the same on every render.
local function display_order(title: string, n: number): { number }
	local order: { number } = {}
	for i = 0, n - 1 do
		table.insert(order, i)
	end
	local h = 1
	for i = 1, #title do
		h = (h * 31 + string.byte(title, i)) % 2147483647
	end
	for i = n, 2, -1 do
		h = (h * 48271) % 2147483647
		local j = h % i + 1
		order[i], order[j] = order[j], order[i]
	end
	return order
end

-- The reader's pick on a question with choices, nil while unanswered.
local function pick_of(state: State, step: Step): number?
	return if choices_of(step) then state.answers[tostring(step.title)] else nil
end

local function missed(state: State, step: Step): boolean
	local pick = pick_of(state, step)
	return pick ~= nil and pick ~= (choices_of(step) :: any).answer
end

-- The file's steps plus a placeholder after the answer step of each missed question
-- whose filling steps (`fills` = its title) have not been written yet.
local function build(state: State)
	local file = flatten(state.tour)
	local filled: { [string]: boolean } = {}
	for _, f in file do
		if type(f.step.fills) == "string" then
			filled[f.step.fills :: string] = true
		end
	end
	local out: { Flat } = {}
	for i, f in file do
		table.insert(out, f)
		local q = file[i - 1]
		if q and missed(state, q.step) and not filled[tostring(q.step.title)] then
			table.insert(out, {
				chapter = f.chapter,
				ci = f.ci,
				si = f.si,
				regen = tostring(q.step.title),
				step = { title = "Regenerating…", blocks = {} },
			})
		end
	end
	state.count = #file
	state.steps = out
end

-- The furthest step the reader may be on: no step after an unanswered question.
local function gate(state: State): number
	for i, f in state.steps do
		if choices_of(f.step) and pick_of(state, f.step) == nil then
			return i
		end
	end
	return #state.steps
end

local function resolve_checkout(state: State)
	local repo = state.repo
	if not repo then
		return
	end
	tern.process.run(
		{ "git", "-C", repo, "rev-parse", "HEAD", state.tour.head .. "^{commit}" },
		{ timeout_ms = 10000 },
		function(r: ProcessResult, _)
			local a, b = string.match(r.stdout, "^(%x+)\n(%x+)")
			state.checkout = r.status == 0 and a ~= nil and a == b
			retry_open(state)
		end
	)
end

local function go_to(state: State, at: number)
	local n = #state.steps
	if n == 0 then
		return
	end
	state.at = math.clamp(at, 1, math.max(1, gate(state)))
	-- Shared with the window half and later opens of the same file: resume here.
	if tern.kv.get("at:" .. state.path) ~= state.at then
		tern.kv.set("at:" .. state.path, state.at)
	end
	state.pending_ask = nil
	prefetch(state)
	if state.follow then
		open_step(state, false)
	end
end

local function validate(tour: any): string?
	if type(tour) ~= "table" then
		return "the file is not a JSON object"
	elseif type(tour.base) ~= "string" or type(tour.head) ~= "string" then
		return "`base` and `head` must be git revisions"
	elseif type(tour.chapters) ~= "table" or #tour.chapters == 0 then
		return "`chapters` is empty"
	end
	return nil
end

-- Reads the file; on a change, keeps the reader's place (or jumps to the answer
-- of a pending question). Returns true when something changed.
local function load(state: State): boolean
	local ok, text = pcall(tern.fs.read, state.path)
	if not ok then
		state.problem = "Cannot read " .. state.path .. ": " .. tostring(text)
		return true
	end
	if text == state.raw then
		return false
	end
	state.raw = text
	local decoded, tour = pcall(tern.json.decode, text)
	local problem = if decoded then validate(tour) else "invalid JSON: " .. first_line(tostring(tour))
	if problem then
		-- An agent mid-write: keep showing the last good tour.
		state.problem = problem
		return true
	end
	state.problem = nil
	local old = state.tour
	local old_count = state.count
	local waiting = if state.steps[state.at] then state.steps[state.at].regen else nil
	state.tour = tour
	build(state)
	if not old or old.base ~= tour.base or old.head ~= tour.head or old.repo ~= tour.repo then
		state.git = {}
		state.checkout = nil
		state.repo = if type(tour.repo) == "string" then tour.repo else nil
		if state.repo then
			resolve_checkout(state)
		else
			tern.process.run(
				{ "git", "-C", dirname(state.path), "rev-parse", "--show-toplevel" },
				{ timeout_ms = 10000 },
				function(r: ProcessResult, _)
					if r.status == 0 then
						state.repo = string.match(r.stdout, "^(.-)%s*$")
						resolve_checkout(state)
						prefetch(state)
					else
						state.problem = "No `repo` in the tour and " .. state.path .. " is not inside a git checkout"
					end
					render(state)
				end
			)
		end
	end
	local pending = state.pending_ask
	local filling: number? = nil
	if waiting then
		for i, f in state.steps do
			if f.step.fills == waiting then
				filling = i
				break
			end
		end
	end
	if filling then
		-- The reader waited on the placeholder: the steps that replace it.
		go_to(state, filling)
	elseif pending and state.count > old_count then
		go_to(state, pending + 1)
	else
		go_to(state, state.at)
	end
	return true
end

local function poll(state: State)
	state.poll = tern.timer(POLL_MS, function(_)
		state.poll = nil
		if not alive(state) then
			return
		end
		if load(state) then
			state.cx:render()
			state.cx:save()
		elseif state.steps[state.at] and state.steps[state.at].regen then
			-- The window half flags an answer no agent received in kv; show it.
			state.cx:render()
		end
		poll(state)
	end)
end

-- Rendering ----------------------------------------------------------------

local BASIS_TONE: { [string]: string } = { fact = "success", inferred = "info", opinion = "warning" }
local MARK_GLYPH: { [string]: string } = { ok = "✔", bad = "✘", note = "★" }

local function problem_node(text: string): Node
	return ui.text({ ui.span("⚠ " .. text, "warning") })
end

local function loading_node(what: string): Node
	return ui.text({ ui.span("… " .. what, "muted") })
end

local function str_list(v: any): { string }
	local out: { string } = {}
	if type(v) == "table" then
		for _, s in v do
			table.insert(out, tostring(s))
		end
	end
	return out
end

local function table_node(head: { string }, rows: any, added: { [string]: boolean }?): Node
	local cols: { Col } = {}
	for i, h in head do
		local label = if added and added[h] then h .. " +" else h
		table.insert(cols, { id = "c" .. i, head = label, grow = if i == #head then 1 else 0 })
	end
	local out: { { Cell } } = {}
	for _, row in (if type(rows) == "table" then rows else {}) :: { any } do
		local cells: { Cell } = {}
		for i = 1, #head do
			local v = if type(row) == "table" then row[i] else nil
			table.insert(cells, if v == nil then "" else tostring(v))
		end
		table.insert(out, cells)
	end
	return ui.table(cols, out)
end

local function code_node(state: State, c: any): Node
	local file: string = c.file
	local at: string = if c.at == "base" then "base" else "head"
	local g = state.git[show_key(state, at, file)]
	local lines = if type(c.lines) == "table" then c.lines else {}
	local from, to = tonumber(lines[1]), tonumber(lines[2] or lines[1])
	local head: { Span | string } = {
		ui.path(file, state.repo),
		ui.span("  " .. at .. (if from then "  L" .. from .. (if to and to ~= from then "–" .. to else "") else ""), "muted"),
	}
	if c.note then
		table.insert(head, ui.span("  " .. tostring(c.note), "accent"))
	end
	if not g or g.pending then
		return ui.card(head, { loading_node("reading " .. file .. " at " .. at) })
	elseif not g.ok then
		return ui.card(head, { problem_node(g.text) })
	end
	local src = split_lines(g.text)
	if not from or not to or from < 1 or to < from or to > #src then
		return ui.card(head, { problem_node(string.format("lines %s–%s are outside the file (%d lines)", tostring(from), tostring(to), #src)) })
	end
	local show = if type(c.show) == "table" then c.show else { from - 2, to + 2 }
	local s = math.clamp(tonumber(show[1]) or from, 1, #src)
	local e = math.clamp(tonumber(show[2]) or to, s, #src)
	local body: { Node } = { ui.code(table.concat(src, "\n", s, e), lang_of(file), s) }
	if type(c.marks) == "table" then
		local rows: { Node } = {}
		for _, m in c.marks do
			if type(m) == "table" then
				table.insert(rows, ui.text({
					ui.span(string.format("%5d ", tonumber(m.line) or 0), "muted num"),
					ui.span("▲ ", "accent"),
					tostring(m.text or ""),
				}))
			end
		end
		table.insert(body, ui.lines(rows))
	end
	return ui.card(head, body)
end

local function diff_node(state: State, d: any): Node
	local file: string = d.file
	local head: { Span | string } = { ui.path(file, state.repo), ui.span("  diff", "muted") }
	local g = state.git["diff:" .. file]
	if not g or g.pending then
		return ui.card(head, { loading_node("diffing " .. file) })
	elseif not g.ok then
		return ui.card(head, { problem_node(g.text) })
	end
	local hunks = hunks_of(g.text)
	if #hunks == 0 then
		return ui.card(head, { problem_node(file .. " did not change between base and head") })
	end
	local picked: { string } = {}
	local want = if type(d.hunks) == "table" then d.hunks else nil
	local span = if type(d.lines) == "table" then d.lines else nil
	if want then
		for _, i in want do
			local h = hunks[(tonumber(i) or -1) + 1]
			if not h then
				return ui.card(head, { problem_node(string.format("hunk %s does not exist (%d hunks)", tostring(i), #hunks)) })
			end
			table.insert(picked, h)
		end
		table.insert(head, ui.span("  hunks " .. table.concat(str_list(want), ", ") .. " of " .. #hunks, "muted"))
	elseif span then
		-- Hunks whose head side overlaps the head lines `from`–`to`.
		local from, to = tonumber(span[1]) or 0, tonumber(span[2] or span[1]) or 0
		for _, h in hunks do
			local start, count = string.match(h, "^@@ %-[%d,]+ %+(%d+),?(%d*)")
			local s = tonumber(start) or 0
			local e = s + math.max((tonumber(count) or 1) - 1, 0)
			if s <= to and e >= from then
				table.insert(picked, h)
			end
		end
		if #picked == 0 then
			return ui.card(head, { problem_node(string.format("no hunk touches head lines %d–%d", from, to)) })
		end
		table.insert(head, ui.span(string.format("  L%d–%d", from, to), "muted"))
	else
		picked = hunks
	end
	return ui.card(head, { ui.diff(table.concat(picked, "\n") .. "\n", file) })
end

-- Mermaid diagrams render natively in a `md` fence. Labels go on one line without the
-- characters that end a statement or start an entity (`"`, `;`, `#`) or an edge label (`|`).
local function mm(s: any): string
	local one = string.gsub(tostring(s or ""), "%s*[\r\n]+%s*", " ")
	local safe = string.gsub(one, '["#;|]', { ['"'] = "'", ["#"] = "＃", [";"] = ",", ["|"] = "¦" })
	return safe
end

local function mermaid_node(src: string): Node
	return ui.md("```mermaid\n" .. src .. "\n```")
end

local FLOW_CLASS: { [string]: string } = {
	changed = "classDef changed stroke:#d29922,stroke-width:3px",
	new = "classDef new stroke:#3fb950,stroke-width:3px",
	external = "classDef external stroke-dasharray:5 4",
}

local function flow_node(f: any): Node
	local lines = { "flowchart TD" }
	local used: { [string]: boolean } = {}
	local nodes = if type(f.nodes) == "table" then f.nodes else {}
	for i, n in nodes do
		if type(n) ~= "table" then
			continue
		end
		local kind = if FLOW_CLASS[n.kind or ""] then n.kind else nil
		local label = mm(n.label) .. (if n.note then "<br/><i>" .. mm(n.note) .. "</i>" else "")
		local shape = if n.start then '(["' .. label .. '"])' else '["' .. label .. '"]'
		table.insert(lines, "  n" .. i .. shape .. (if kind then ":::" .. kind else ""))
		if kind then
			used[kind] = true
		end
		local prev = nodes[i - 1]
		if prev and not n.start then
			local edge = if type(prev) == "table" and prev.next then "-->|" .. mm(prev.next) .. "|" else "-->"
			table.insert(lines, "  n" .. (i - 1) .. " " .. edge .. " n" .. i)
		end
	end
	for kind in used do
		table.insert(lines, "  " .. FLOW_CLASS[kind])
	end
	return ui.col({
		mermaid_node(table.concat(lines, "\n")),
		ui.text({ ui.span("orange: changed · green: new · dashed: external · rounded: starts on its own", "dim") }),
	})
end

-- A timeline is a sequence diagram: lanes are participants, `to` events are messages
-- (✘ ones end in a cross), the rest are notes over their lane.
local function timeline_node(t: any): Node
	local lines = { "sequenceDiagram" }
	local ids: { [string]: string } = {}
	for i, lane in str_list(t.lanes) do
		ids[lane] = "L" .. i
		table.insert(lines, "  participant L" .. i .. " as " .. mm(lane))
	end
	for _, ev in (if type(t.events) == "table" then t.events else {}) :: { any } do
		local from = if type(ev) == "table" then ids[tostring(ev.lane)] else nil
		if not from then
			continue
		end
		local mark = MARK_GLYPH[ev.mark or ""]
		local text = (if mark then mark .. " " else "") .. mm(ev.text)
		local to = if ev.to then ids[tostring(ev.to)] else nil
		if to then
			table.insert(lines, "  " .. from .. (if ev.mark == "bad" then "-x" else "->>") .. to .. ": " .. text)
		else
			table.insert(lines, "  Note over " .. from .. ": " .. text)
		end
	end
	return mermaid_node(table.concat(lines, "\n"))
end

local ROLE_ORDER: { [string]: number } = { core = 1, mechanical = 2, test = 3, config = 4, docs = 5 }

local function files_node(state: State, f: any): Node
	local g = state.git.numstat
	if not g or g.pending then
		return loading_node("reading changed files")
	elseif not g.ok then
		return problem_node(g.text)
	end
	local roles: { [string]: any } = {}
	for _, r in (if type(f.roles) == "table" then f.roles else {}) :: { any } do
		if type(r) == "table" and type(r.file) == "string" then
			roles[r.file] = r
		end
	end
	local entries = {}
	for _, line in split_lines(g.text) do
		local add, del, file = string.match(line, "^(%S+)\t(%S+)\t(.+)$")
		if file then
			local r = roles[file]
			table.insert(entries, {
				file = file,
				add = tonumber(add) or 0,
				del = tonumber(del) or 0,
				role = if r then tostring(r.role or "") else "",
				note = if r and r.note then tostring(r.note) else "",
			})
		end
	end
	table.sort(entries, function(a, b)
		local ra, rb = ROLE_ORDER[a.role] or 9, ROLE_ORDER[b.role] or 9
		if ra ~= rb then
			return ra < rb
		end
		return a.file < b.file
	end)
	-- Narrow panes hide the lowest priority first: the note, then the role; the path
	-- shrinks from its start instead of hiding, and the counts always stay.
	local cols: { Col } = {
		{ id = "file", head = "File", truncate = "start", grow = 1, priority = 4 },
		{ id = "add", head = "+", align = "end", priority = 3 },
		{ id = "del", head = "−", align = "end", priority = 3 },
		{ id = "role", head = "Role", priority = 2 },
		{ id = "note", head = "Note", grow = 1, priority = 1 },
	}
	local rows: { { Cell } } = {}
	for _, e in entries do
		table.insert(rows, {
			{ ui.path(e.file, state.repo) },
			{ ui.span("+" .. e.add, "success num") },
			{ ui.span("−" .. e.del, "error num") },
			{ ui.span(e.role, if e.role == "core" then "strong" else "muted") },
			e.note,
		})
	end
	return ui.table(cols, rows)
end

local function target_node(state: State): Node
	local kv: { { Spans } } = {}
	local pr = state.tour.pr
	if type(pr) == "table" and pr.number then
		local label = "#" .. tostring(pr.number) .. (if pr.title then " " .. tostring(pr.title) else "")
		table.insert(kv, { "PR", if pr.url then { ui.link(label, tostring(pr.url)) } else label })
	end
	local function ref(name: string, which: string): string
		local r = if type(pr) == "table" then pr[which .. "_ref"] else nil
		local sha = string.sub(state.tour[which], 1, 12)
		return if r then tostring(r) .. "  " .. sha else sha
	end
	table.insert(kv, { "base", ref("base", "base") })
	table.insert(kv, { "head", ref("head", "head") })
	local stat = state.git.shortstat
	if stat and stat.ok then
		table.insert(kv, { "size", string.match(stat.text, "^%s*(.-)%s*$") or "" })
	end
	local kids: { Node } = { ui.kv(kv) }
	local log = state.git.log
	if not log or log.pending then
		table.insert(kids, loading_node("reading commits"))
	elseif not log.ok then
		table.insert(kids, problem_node(log.text))
	else
		local rows: { Node } = {}
		for _, line in split_lines(log.text) do
			local sha, subject = string.match(line, "^(%S+)\t(.*)$")
			if sha then
				table.insert(rows, ui.text({ ui.span(sha .. "  ", "accent num"), subject or "" }))
			end
		end
		table.insert(kids, ui.lines(rows))
	end
	return ui.card({ ui.span("The change", "strong") }, kids)
end

local function block_node(state: State, b: any): Node
	if type(b) ~= "table" then
		return problem_node("a block must be an object")
	elseif type(b.p) == "string" then
		local tone = BASIS_TONE[b.basis or ""]
		if tone then
			return ui.row({ ui.badge(b.basis, tone), ui.md(b.p) })
		end
		return ui.md(b.p)
	elseif type(b.quote) == "string" then
		return ui.md("> " .. string.gsub(b.quote, "\n", "\n> "))
	elseif type(b.list) == "table" then
		local items: { string } = {}
		for _, item in str_list(b.list) do
			table.insert(items, "- " .. item)
		end
		return ui.md(table.concat(items, "\n"))
	elseif type(b.pre) == "string" then
		local n = ui.code(b.pre, nil)
		local p = (n.p or {}) :: { [string]: any }
		p.numbers = false
		n.p = p
		return n
	elseif type(b.table) == "table" then
		return table_node(str_list(b.table.head), b.table.rows)
	elseif type(b.code) == "table" and type(b.code.file) == "string" then
		return code_node(state, b.code)
	elseif type(b.diff) == "table" and type(b.diff.file) == "string" then
		return diff_node(state, b.diff)
	elseif type(b.snippet) == "table" then
		local s = b.snippet
		local lang = if type(s.lang) == "string" then s.lang else nil
		local n = ui.code(tostring(s.text or ""), lang)
		return ui.card({ ui.span("Example", "warning strong"), ui.span("  " .. tostring(s.label or ""), "muted") }, { n })
	elseif type(b.rows) == "table" then
		local r = b.rows
		local added: { [string]: boolean } = {}
		for _, a in str_list(r.added) do
			added[a] = true
		end
		return ui.card(
			{ ui.span(if type(r.tag) == "string" then r.tag else "Example", "accent strong"), ui.span("  " .. tostring(r.label or ""), "muted") },
			{ table_node(str_list(r.head), r.data, added) }
		)
	elseif type(b.mermaid) == "string" then
		return mermaid_node(b.mermaid)
	elseif type(b.flow) == "table" then
		return flow_node(b.flow)
	elseif type(b.timeline) == "table" then
		return timeline_node(b.timeline)
	elseif type(b.files) == "table" then
		return files_node(state, b.files)
	elseif b.target then
		return target_node(state)
	end
	local keys: { string } = {}
	for k in b do
		table.insert(keys, tostring(k))
	end
	return problem_node("unknown block: " .. table.concat(keys, ", "))
end

-- The question step titled `title`.
local function question_titled(state: State, title: string): Step?
	for _, f in state.steps do
		if f.step.question and f.step.title == title then
			return f.step
		end
	end
	return nil
end

local function choices_node(state: State, step: Step, c: any): Node
	local pick = pick_of(state, step)
	local rows: { Node } = {}
	for pos, i in display_order(tostring(step.title), #c.options) do
		local mark, tone = "  ", "dim"
		if pick ~= nil and i == c.answer then
			mark, tone = "✔ ", "success"
		elseif pick == i then
			mark, tone = "✘ ", "error"
		end
		table.insert(rows, ui.row({
			ui.text({ ui.span(mark, tone), ui.span(tostring(pos), "accent num") }),
			ui.md(option_text(c, i)),
		}))
	end
	table.insert(rows, ui.text({
		ui.span(if pick == -1 then "· " else "  ", "muted"),
		ui.span("0", "accent num"),
		ui.span("  I don't know", "muted"),
	}))
	local verdict: Span
	if pick == nil then
		verdict = ui.span(string.format("Pick 1–%d (0 if you don't know) to go on.", #c.options), "accent")
	elseif pick == c.answer then
		verdict = ui.span("✔ Right. → for why.", "success")
	elseif pick == -1 then
		verdict = ui.span("→ for the answer; the tour is adding steps for this gap after it.", "warning")
	else
		verdict = ui.span("✘ Not this one. → for why; the tour is adding steps for your answer after it.", "warning")
	end
	table.insert(rows, ui.text({ verdict }))
	return ui.col(rows)
end

-- Whether the window half found no agent to send the miss on `title` to.
local function unsent(state: State, title: string): boolean
	local flags = tern.kv.get("unsent:" .. state.path)
	return type(flags) == "table" and flags[title] == true
end

local function regen_view(state: State, flat: Flat): Node
	local title = flat.regen :: string
	local kids: { Node } = {
		ui.text({
			ui.span(flat.chapter, "muted"),
			ui.span(string.format("   %d / %d", state.at, #state.steps), "dim num"),
		}),
		ui.row({ ui.badge("Regenerating", "warning"), ui.text({ ui.span("Filling the gap in “" .. title .. "”", "strong") }) }),
	}
	if unsent(state, title) then
		table.insert(kids, problem_node("No agent got your answer: set the tour's `agent`, or start one in its repo, then ⏎ to send it again."))
	else
		table.insert(kids, ui.text({ ui.span("The agent is writing steps around your answer; they replace this one.", "accent") }))
		table.insert(kids, ui.progress(nil, ""))
	end
	table.insert(kids, ui.text({ ui.span("→ goes on without them.", "muted") }))
	return ui.col(kids)
end

local function step_view(state: State): Node
	local flat = state.steps[state.at]
	if flat.regen then
		return regen_view(state, flat)
	end
	local step = flat.step
	local kids: { Node } = {
		ui.text({
			ui.span(flat.chapter, "muted"),
			ui.span(string.format("   %d / %d", state.at, #state.steps), "dim num"),
		}),
	}
	local title: { Node } = {}
	if step.question then
		table.insert(title, ui.badge("Question", "accent"))
	end
	table.insert(title, ui.text({ ui.span(tostring(step.title or ""), "strong") }))
	table.insert(kids, ui.row(title))
	if type(step.asked) == "string" then
		table.insert(kids, ui.md("> **You asked:** " .. step.asked))
	end
	local prev = state.steps[state.at - 1]
	if type(step.fills) == "string" and not (prev and prev.step.fills == step.fills) then
		local q = question_titled(state, step.fills :: string)
		local c = if q then choices_of(q) else nil
		local pick = if q then pick_of(state, q) else nil
		local said = if not c or pick == nil then ""
			elseif pick == -1 then " you didn't know."
			else " you picked “" .. option_text(c, pick) .. "”."
		table.insert(kids, ui.md("> **Filling the gap** in “" .. step.fills .. "”:" .. said))
	end
	for _, b in step.blocks or {} do
		local ok, node = pcall(block_node, state, b)
		table.insert(kids, if ok then node else problem_node(first_line(tostring(node))))
	end
	local c = choices_of(step)
	if c then
		table.insert(kids, choices_node(state, step, c))
	elseif step.question then
		table.insert(kids, ui.text({ ui.span("Think of your answer, then → for it.", "muted") }))
	end
	return ui.col(kids)
end

local LIST_ID = "main.toc."

local function toc_view(state: State): Node
	local items: { Item } = {}
	local last = -1
	for i, f in state.steps do
		local label: { Span | string } = {}
		if f.ci ~= last then
			last = f.ci
			table.insert(label, ui.span(f.chapter .. "  ", "muted"))
		else
			table.insert(label, ui.span(string.rep(" ", 2), "muted"))
		end
		table.insert(label, ui.span(tostring(f.step.title or ""), if i == state.at then "strong" else nil))
		table.insert(items, {
			label = label,
			icon = if f.regen then "refresh-cw" elseif f.step.question then "help" elseif i == state.at then "chevron-right" else nil,
			value = ui.span(tostring(i), "dim num"),
		})
	end
	local list = ui.list(items)
	for i, kid in list.c or {} do
		local p: { [string]: any } = kid.p or {}
		p.key = "s" .. i
		kid.p = p
	end
	local p: { [string]: any } = list.p or {}
	p.key = "toc"
	p.selected = LIST_ID .. "s" .. state.at
	p.max = { lines = math.max(6, state.cx.rows - 6) }
	list.p = p
	return ui.col({ ui.text({ ui.span(tostring(state.tour.title or "Tour"), "strong") }), list })
end

local function dock_view(state: State): Node
	local lines: { Node } = {}
	if state.problem then
		table.insert(lines, ui.text({ ui.span("⚠ " .. first_line(state.problem), "warning") }))
	end
	if state.pending_ask then
		table.insert(lines, ui.text({ ui.span("Asked the agent: the answer lands as the next step.", "accent") }))
	end
	local flat = state.steps[state.at]
	local c = if flat then choices_of(flat.step) else nil
	local legend = if state.toc
		then "↑↓ step  ⏎ go  t/esc back"
		elseif c and pick_of(state, flat.step) == nil then string.format("1–%d answer  0 don't know  ← back  t contents  ? ask", #c.options)
		elseif flat and flat.regen and unsent(state, flat.regen :: string) then "← → step  ⏎ send the answer again  t contents"
		elseif flat and flat.regen then "← → step  t contents"
		else "← → step  [ ] chapter  t contents  o open code  f follow " .. (if state.follow then "on" else "off") .. "  ? ask"
	table.insert(lines, ui.text({ ui.span(legend, "dim") }))
	return ui.col({ ui.lines(lines) })
end

-- Block --------------------------------------------------------------------

local function chapter_jump(state: State, dir: number)
	local cur = state.steps[state.at]
	if not cur then
		return
	end
	if dir > 0 then
		for i = state.at + 1, #state.steps do
			if state.steps[i].ci ~= cur.ci then
				go_to(state, i)
				return
			end
		end
	else
		-- To the start of this chapter, or of the previous one when already there.
		local target = cur.ci
		if cur.si == 1 then
			target -= 1
		end
		for i, f in state.steps do
			if f.ci == target then
				go_to(state, i)
				return
			end
		end
	end
end

local function ask(state: State)
	local n = state.steps[state.at].n
	if not n then
		return
	end
	state.pending_ask = state.at
	state.cx:open(LINK .. "ask?path=" .. url_encode(state.path) .. "&at=" .. n)
end

-- Sends a missed question's pick to the agent, which fills the gap (pr-tour skill).
local function send_miss(state: State, flat: Flat)
	local pick = pick_of(state, flat.step)
	if flat.n and pick ~= nil then
		state.cx:open(LINK .. "answer?path=" .. url_encode(state.path) .. "&at=" .. flat.n .. "&pick=" .. pick)
	end
end

-- `key`: 1–n picks the option shown at that position, 0 is "I don't know". Answers are final.
local function answer(state: State, key: number): boolean
	local flat = state.steps[state.at]
	local c = choices_of(flat.step)
	if not c or pick_of(state, flat.step) ~= nil then
		return false
	end
	local title = tostring(flat.step.title)
	local order = display_order(title, #c.options)
	if key > #order then
		return false
	end
	state.answers[title] = if key == 0 then -1 else order[key]
	tern.kv.set("answers:" .. state.path, state.answers)
	build(state)
	prefetch(state)
	if missed(state, flat.step) then
		send_miss(state, flat)
	end
	return true
end

tern.block.define("tour", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local s = if type(saved) == "table" then saved else {}
		local path = args[1] or s.path or ""
		local state: State = {
			cx = cx,
			path = path,
			raw = nil,
			tour = nil,
			steps = {},
			count = 0,
			at = tonumber(s.at) or tonumber(tern.kv.get("at:" .. path)) or 1,
			answers = {},
			problem = nil,
			repo = nil,
			checkout = nil,
			reopen = nil,
			git = {},
			follow = s.follow ~= false,
			toc = false,
			pending_ask = nil,
			poll = nil,
		}
		running[cx.pane] = state
		local answers = tern.kv.get("answers:" .. path)
		if type(answers) == "table" then
			state.answers = answers
		end
		tern.kv.set("pane:" .. cx.pane, path)
		if path == "" then
			state.problem = "No tour file: open a *.tour.json file (tern open FILE)"
		else
			load(state)
			poll(state)
		end
		return state
	end,

	title = function(state: State): string?
		local t = if state.tour then tostring(state.tour.title or "") else ""
		return if t ~= "" then "Tour · " .. t else "Diff Tour"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local main: Node
		if #state.steps == 0 then
			main = ui.col({
				ui.text({ ui.span("Diff Tour", "strong") }),
				problem_node(state.problem or "The tour has no steps"),
			})
		elseif state.toc then
			main = toc_view(state)
		else
			main = step_view(state)
		end
		return { main = main, dock = dock_view(state) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if state.toc then
			if key.name == "up" or k == "k" then
				state.at = math.max(1, state.at - 1)
			elseif key.name == "down" or k == "j" then
				state.at = math.min(#state.steps, state.at + 1)
			elseif key.name == "enter" or key.name == "right" or k == "l" then
				state.toc = false
				go_to(state, state.at)
			elseif key.name == "escape" or k == "t" or k == "q" then
				state.toc = false
			else
				return false
			end
			return true
		end
		local flat = state.steps[state.at]
		if flat and string.match(k, "^%d$") then
			return answer(state, tonumber(k) :: number)
		elseif flat and flat.regen and (k == "o" or key.name == "enter") then
			if unsent(state, flat.regen :: string) then
				for _, f in state.steps do
					if f.step.question and f.step.title == flat.regen then
						send_miss(state, f)
						break
					end
				end
			end
		elseif key.name == "right" or k == "l" or k == "n" or key.name == "space" then
			go_to(state, state.at + 1)
		elseif key.name == "left" or k == "h" or k == "p" or key.name == "backspace" then
			go_to(state, state.at - 1)
		elseif k == "]" then
			chapter_jump(state, 1)
		elseif k == "[" then
			chapter_jump(state, -1)
		elseif key.name == "home" or k == "g" then
			go_to(state, 1)
		elseif key.name == "end" or k == "G" then
			go_to(state, #state.steps)
		elseif k == "t" then
			state.toc = true
		elseif k == "o" or key.name == "enter" then
			open_step(state, true)
		elseif k == "f" then
			state.follow = not state.follow
			if state.follow then
				open_step(state, false)
			end
		elseif k == "?" then
			if #state.steps > 0 then
				ask(state)
			end
		elseif k == "r" then
			state.raw = nil
			state.git = {}
			load(state)
		elseif k == "q" then
			retire(state)
			cx:exit(0)
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local i = tonumber(string.match(ev.item, "^" .. string.gsub(LIST_ID, "%.", "%%.") .. "s(%d+)$"))
			if i then
				state.at = i
				if ev.ev == "activate" then
					state.toc = false
					go_to(state, i)
				end
			end
		end
	end,

	save = function(state: State): any
		return { path = state.path, at = state.at, follow = state.follow }
	end,
})
