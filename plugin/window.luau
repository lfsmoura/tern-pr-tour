--!strict
-- The window half: opens `*.tour.json` files as tour blocks (so an agent runs
-- `tern open --split right FILE`), and serves the `tern-difftour://` links the
-- block uses for what a host block cannot do itself: open code in the preview
-- beside it, and ask the agent that wrote the tour a question.

local KIND = "diff-tour.tour"
local LINK = "tern-difftour://"
local MAX_RECENT = 20

local function url_decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

local function query(url: string): { [string]: string }
	local out: { [string]: string } = {}
	local q = string.match(url, "%?(.*)$") or ""
	for k, v in string.gmatch(q, "([^&=]+)=([^&]*)") do
		out[k] = url_decode(v)
	end
	return out
end

local function read_tour(path: string): any
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		return nil
	end
	local decoded, tour = pcall(tern.json.decode, text)
	return if decoded and type(tour) == "table" then tour else nil
end

local function remember(path: string)
	local tour = read_tour(path)
	local list: { any } = {}
	table.insert(list, { path = path, title = if tour then tostring(tour.title or "") else "" })
	local stored = tern.kv.get("recent")
	for _, r in (if type(stored) == "table" then stored else {}) :: { any } do
		if type(r) == "table" and r.path ~= path and #list < MAX_RECENT then
			table.insert(list, r)
		end
	end
	tern.kv.set("recent", list)
end

-- The tour block showing `path`; each block records its file under `pane:<id>`.
local function shown(cx: WindowCx, path: string): number?
	for _, p in cx.session:panes() do
		if p.block == KIND and tern.kv.get("pane:" .. p.pane) == path then
			return p.pane
		end
	end
	return nil
end

-- `tern open FILE.tour.json`: the CLI wants a block back, so an already shown tour
-- is closed and opened again here; the block resumes at the step it was on.
tern.route.open(function(req: OpenRequest, cx: WindowCx): RouteDecision?
	if not string.match(req.path, "%.tour%.json$") then
		return nil
	end
	local old = shown(cx, req.path)
	if old then
		cx.layout:close(old)
	end
	remember(req.path)
	return { block = KIND, args = { req.path } }
end)

local function open_tour(cx: WindowCx, path: string)
	local pane = shown(cx, path)
	if pane then
		cx.layout:focus(pane)
	elseif cx:new_block(KIND, { path }, "beside") then
		remember(path)
	else
		cx:toast("error", "Diff Tour is not loaded on this host", "Install the plugin where the tour file lives.")
	end
end

tern.command({
	id = "recent",
	title = "Diff Tour: open a recent tour",
	icon = "map",
	run = function(cx: WindowCx)
		local items: { PickItem } = {}
		local stored = tern.kv.get("recent")
		for _, r in (if type(stored) == "table" then stored else {}) :: { any } do
			if type(r) == "table" and type(r.path) == "string" and tern.fs.exists(r.path) then
				local title = if r.title ~= "" then r.title else string.match(r.path, "[^/]+$") or r.path
				table.insert(items, { label = title, detail = r.path, path = r.path })
			end
		end
		if #items == 0 then
			cx:toast("info", "No tours yet", "Ask omp for a PR tour (pr-tour skill), or `tern open FILE.tour.json`.")
			return
		end
		cx:pick({ items = items, placeholder = "Open a tour", icon = "map", action = "open" })
			:next(function(item: PickItem?, _err: string?, cx2: WindowCx?)
				if item and cx2 then
					open_tour(cx2, item.path)
				end
			end)
	end,
})

-- Asking -------------------------------------------------------------------

-- The agent that wrote the tour (`agent`: its pane), else an agent block in the tour's repo.
local function agent_pane(cx: WindowCx, tour: any): number?
	local id = tonumber(tour.agent)
	if id and cx.session:pane(id) then
		return id
	end
	local ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if ok and type(tour.repo) == "string" then
		for _, a in agents do
			if a.state ~= "exited" and (a.cwd == tour.repo or string.sub(a.cwd, 1, #tour.repo + 1) == tour.repo .. "/") then
				return a.pane
			end
		end
	end
	return nil
end

local function send(cx: WindowCx, path: string, tour: any, at: number, step: any, question: string)
	local pane = agent_pane(cx, tour)
	if not pane then
		cx:toast("error", "No agent to ask", "Set `agent` in the tour to the pane of the omp that wrote it ($TERN_PANE).")
		return
	end
	-- One line: it is typed into the agent's prompt.
	local text = string.format(
		'[diff-tour ask] %s — tour %s, step %d ("%s"). Answer per the pr-tour skill: insert 1–2 steps right after that step with "asked" set, then check the tour.',
		(string.gsub(question, "%s+", " ")),
		path,
		at,
		(string.gsub(tostring(step.title or ""), "%s+", " "))
	)
	local info = cx.session:pane(pane)
	local asked = info ~= nil and info.kind == "agent" and pcall(function()
		cx.agents:ask(pane, text)
	end)
	if not asked then
		cx:run(pane, text .. "\r")
	end
	cx:toast("info", "Asked the agent", "Its answer appears as the next step of the tour.")
end

local function ask(cx: WindowCx, path: string, at: number)
	local tour = read_tour(path)
	if not tour then
		cx:toast("error", "Cannot read the tour", path)
		return
	end
	local n = 0
	local step: any = nil
	for _, ch in tour.chapters or {} do
		for _, s in ch.steps or {} do
			n += 1
			if n == at then
				step = s
			end
		end
	end
	if not step then
		return
	end
	local function own(cx2: WindowCx)
		cx2:prompt({ placeholder = "Ask about this step", icon = "help", action = "ask" })
			:next(function(text: string?, _err: string?, cx3: WindowCx?)
				if text and cx3 and string.match(text, "%S") then
					send(cx3, path, tour, at, step, text)
				end
			end)
	end
	local items: { PickItem } = {}
	for _, q in (if type(step.asks) == "table" then step.asks else {}) :: { any } do
		table.insert(items, { label = tostring(q), group = "Suggested" })
	end
	if #items == 0 then
		own(cx)
		return
	end
	table.insert(items, { label = "Ask something else…", group = "Your own", own = true })
	cx:pick({ items = items, placeholder = "Ask about this step", icon = "help", action = "ask" })
		:next(function(item: PickItem?, _err: string?, cx2: WindowCx?)
			if not item or not cx2 then
				return
			elseif item.own then
				own(cx2)
			else
				send(cx2, path, tour, at, step, item.label)
			end
		end)
end

-- A preview opens beside the focused pane, so a follow open while the tour's tab is
-- hidden (an agent edit, an answer landing, a git read finishing) would land in the
-- tab on screen. It waits here, by tour pane, until focus enters the tour's tab.
local deferred: { [number]: { path: string, line: number? } } = {}

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	for tour, want in deferred do
		if cx.session:tab_of(tour) == ev.tab then
			deferred[tour] = nil
			cx.docs:open(want.path, { how = "preview", line = want.line })
		end
	end
end)

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #LINK) ~= LINK then
		return nil
	end
	local verb = string.match(string.sub(link.url, #LINK + 1), "^([%w_]+)")
	local q = query(link.url)
	if verb == "show" and q.path then
		local tour = tonumber(q.pane)
		local focused = cx.session:focused()
		local line = tonumber(q.line)
		if tour and not (focused and cx.session:tab_of(tour) == cx.session:tab_of(focused)) then
			deferred[tour] = { path = q.path, line = line }
		else
			if tour then
				deferred[tour] = nil
			end
			local pane = cx.docs:open(q.path, { how = "preview", line = line })
			if q.focus == "1" then
				cx.layout:focus(pane)
			end
		end
	elseif verb == "ask" and q.path then
		ask(cx, q.path, tonumber(q.at) or 1)
	end
	return { handled = true }
end)
