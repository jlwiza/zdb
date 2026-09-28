-- zdb.lua — Neovim plugin for zdb live debugger
--
-- Keybindings:
--   <leader>db     toggle breakpoint on current line
--   <leader>dd     open/close the debugger side panel
--   <leader>dc     continue
--   <leader>ds     step in
--   <leader>dn     step over
--   <leader>do     step out
--   <leader>dq     quit debuggee
--
-- In the debugger side panel:
--   c       continue       s       step in
--   n       step over      o       step out
--   q       quit program   i/p     edit the inline inspector
--   v       list all vars  x       clear output
--   Enter   activate row   g       jump to stopped source
--   dd      remove the breakpoint row under the cursor
--   [ / ]   previous/next inspected data page
--   Mouse   click controls/data; drag the split border to resize

local M = {}

-- ============================================================================
-- Config
-- ============================================================================

M.config = {
	breakpoint_file = "zdb_breakpoints.zon",
	state_file = "zdb_state.txt",
	command_file = "zdb_command.txt",
	output_file = "zdb_output.txt",
	sign_text = "●",
	sign_hl = "DiagnosticError",
	poll_ms = 100,
	panel_width = 64,
	surface_file = "debug.zdb",
	open_on_stop = true,
	-- Click the gutter of a .zig window to toggle a breakpoint. Off by default:
	-- it maps <LeftMouse> globally, which other plugins and user maps may own.
	gutter_click = false,
	-- Global keys. Set one to false to skip it, or keys = false to map none.
	keys = {
		toggle_breakpoint = "<leader>db",
		panel = "<leader>dd",
		continue = "<leader>dc",
		step = "<leader>ds",
		next = "<leader>dn",
		out = "<leader>do",
		quit = "<leader>dq",
		clear = "<leader>dx",
	},
}

-- ============================================================================
-- State
-- ============================================================================

local breakpoints = {}
local panel_buf = nil
local panel_win = nil
local poll_timer = nil
local last_state_content = nil
local last_output_content = nil
local cached_root = nil
local current_state = nil
local output_lines = {}
local surface_rows = {}
local inspector_line = nil
local inspector_editing = false
local inspector_snapshot = nil
local inspector_guarding = false
local inspection = { base = nil, page = 0, total = nil, page_size = 8, paged = false }
local inspection_request_id = 0
local ns = vim.api.nvim_create_namespace("zdb")
local hl_ns = vim.api.nvim_create_namespace("zdb_hl")
local stop_ns = vim.api.nvim_create_namespace("zdb_stop")
local augroup = nil

-- ============================================================================
-- Highlight groups
-- ============================================================================

local function setup_highlights()
	local hi = vim.api.nvim_set_hl

	-- Status
	hi(0, "ZdbStopped", { fg = "#ff6b6b", bold = true })
	hi(0, "ZdbRunning", { fg = "#69db7c", bold = true })
	hi(0, "ZdbWaiting", { fg = "#868e96", bold = true })
	hi(0, "ZdbCurrentLine", { bg = "#3b3045" })

	-- Panel structure
	hi(0, "ZdbSeparator", { fg = "#495057" })
	hi(0, "ZdbHeader", { fg = "#ffd43b", bold = true })
	hi(0, "ZdbLabel", { fg = "#868e96" }) -- "File:", "Line:", etc.
	hi(0, "ZdbValue", { fg = "#e9ecef" }) -- file path, line number

	-- Variable display
	hi(0, "ZdbVarName", { fg = "#74c0fc" }) -- variable names
	hi(0, "ZdbTypeName", { fg = "#da77f2" }) -- final type name (AnimationTimeline)
	hi(0, "ZdbTypeModule", { fg = "#ffa94d" }) -- module path prefix (timeline.)
	hi(0, "ZdbTypeSigil", { fg = "#868e96" }) -- *, [], ? etc.
	hi(0, "ZdbFieldName", { fg = "#91a7ff" }) -- .field names
	hi(0, "ZdbString", { fg = "#69db7c" }) -- string values
	hi(0, "ZdbNumber", { fg = "#ffa94d" }) -- numeric values
	hi(0, "ZdbKeyword", { fg = "#ff922b" }) -- null, true, false
	hi(0, "ZdbEnum", { fg = "#e599f7" }) -- .enum_tag
	hi(0, "ZdbFn", { fg = "#868e96", italic = true }) -- <fn>
	hi(0, "ZdbPtr", { fg = "#868e96", italic = true }) -- ptr
	hi(0, "ZdbBrace", { fg = "#868e96" }) -- { }

	-- Output
	hi(0, "ZdbPrompt", { fg = "#ffd43b", bold = true }) -- >>> query
	hi(0, "ZdbHelpKey", { fg = "#74c0fc", bold = true }) -- [c], [s], etc.
	hi(0, "ZdbHelpText", { fg = "#868e96" })
end

-- ============================================================================
-- Breakpoint toggling
-- ============================================================================

local function get_project_root()
	local markers = { ".git", "build.zig", "build.zig.zon" }
	local path = vim.fn.expand("%:p:h")
	while path and path ~= "/" do
		for _, marker in ipairs(markers) do
			if vim.fn.isdirectory(path .. "/" .. marker) == 1 or vim.fn.filereadable(path .. "/" .. marker) == 1 then
				return path
			end
		end
		path = vim.fn.fnamemodify(path, ":h")
	end
	return vim.fn.getcwd()
end

local function relative_path(filepath, root)
	if filepath:sub(1, #root) == root then
		return filepath:sub(#root + 2)
	end
	return filepath
end

local function write_breakpoints_zon(root)
	local lines = { ".{", "    .breakpoints = .{" }
	for filepath, file_bps in pairs(breakpoints) do
		local rel = relative_path(filepath, root)
		for line, enabled in pairs(file_bps) do
			if enabled then
				table.insert(lines, string.format('        .{ .file = "%s", .line = %d },', rel, line))
			end
		end
	end
	table.insert(lines, "    },")
	table.insert(lines, "}")
	table.insert(lines, "")

	local zon_path = root .. "/" .. M.config.breakpoint_file
	local f = io.open(zon_path, "w")
	if f then
		f:write(table.concat(lines, "\n"))
		f:close()
	end
end

local function load_breakpoints_zon(root)
	local path = root .. "/" .. M.config.breakpoint_file
	local f = io.open(path, "r")
	if not f then
		return
	end
	local content = f:read("*all")
	f:close()
	breakpoints = {}
	for file, line in content:gmatch('%.file%s*=%s*"([^"]+)"%s*,%s*%.line%s*=%s*(%d+)') do
		local full = file:sub(1, 1) == "/" and file or (root .. "/" .. file)
		breakpoints[full] = breakpoints[full] or {}
		breakpoints[full][tonumber(line)] = true
	end
end

local function update_signs(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local file_bps = breakpoints[filepath]
	if not file_bps then
		return
	end

	for line, enabled in pairs(file_bps) do
		if enabled then
			vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
				sign_text = M.config.sign_text,
				sign_hl_group = M.config.sign_hl,
			})
		end
	end
end

local function stopped_path()
	if not current_state or current_state.status ~= "stopped" or not current_state.file then
		return nil
	end
	if current_state.file:sub(1, 1) == "/" then
		return current_state.file
	end
	return (cached_root or get_project_root()) .. "/" .. current_state.file
end

local function mark_stopped_line()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, stop_ns, 0, -1)
		end
	end
	local target = stopped_path()
	local line = current_state and tonumber(current_state.line) or nil
	if not target or not line then
		return
	end
	local buf = vim.fn.bufnr(target)
	if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
		pcall(vim.api.nvim_buf_set_extmark, buf, stop_ns, line - 1, 0, {
			sign_text = "▶",
			sign_hl_group = "ZdbStopped",
			line_hl_group = "ZdbCurrentLine",
			priority = 200,
		})
	end
end

local function source_window()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) ~= panel_buf then
			return win
		end
	end
	return nil
end

local function goto_stopped_source(create_window)
	local target = stopped_path()
	local line = current_state and tonumber(current_state.line) or nil
	if not target or not line then
		vim.notify("zdb: no stopped source location", vim.log.levels.WARN)
		return
	end

	local win = source_window()
	if not win and create_window then
		vim.cmd("split " .. vim.fn.fnameescape(target))
		win = vim.api.nvim_get_current_win()
	elseif not win then
		return
	end

	local buf = vim.fn.bufnr(target)
	if buf == -1 then
		vim.api.nvim_win_call(win, function()
			vim.cmd("edit " .. vim.fn.fnameescape(target))
		end)
	else
		vim.api.nvim_win_set_buf(win, buf)
	end
	pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
	mark_stopped_line()
end

local function toggle_breakpoint()
	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local line = vim.api.nvim_win_get_cursor(0)[1]

	if not breakpoints[filepath] then
		breakpoints[filepath] = {}
	end

	if breakpoints[filepath][line] then
		breakpoints[filepath][line] = nil
	else
		breakpoints[filepath][line] = true
	end

	update_signs(bufnr)
	cached_root = cached_root or get_project_root()
	write_breakpoints_zon(cached_root)
end

-- Preserve Neovim's ordinary mouse click everywhere except the gutter of a
-- Zig source window. Expression mappings cannot move the cursor or edit a
-- buffer directly, so the actual toggle runs immediately after the click
-- mapping has returned.
local function source_gutter_click()
	local mouse = vim.fn.getmousepos()
	if mouse.winid == 0 or mouse.line < 1 then
		return "<LeftMouse>"
	end

	local info = vim.fn.getwininfo(mouse.winid)[1]
	local buf = vim.api.nvim_win_get_buf(mouse.winid)
	local name = vim.api.nvim_buf_get_name(buf)
	local in_gutter = info and mouse.column <= (info.textoff or 0)
	if not in_gutter or not name:match("%.zig$") then
		return "<LeftMouse>"
	end

	local target_win = mouse.winid
	local target_line = mouse.line
	vim.schedule(function()
		if not vim.api.nvim_win_is_valid(target_win) then
			return
		end
		vim.api.nvim_set_current_win(target_win)
		vim.api.nvim_win_set_cursor(target_win, { target_line, 0 })
		toggle_breakpoint()
	end)
	return "<Ignore>"
end

-- ============================================================================
-- Command sending
-- ============================================================================

local function send_command(cmd)
	local root = cached_root or get_project_root()
	local cmd_path = root .. "/" .. M.config.command_file
	local f = io.open(cmd_path, "w")
	if f then
		f:write(cmd .. "\n")
		f:flush()
		f:close()
	end
end

-- ============================================================================
-- Tab completion for variable inspection
-- ============================================================================

-- Cache of known field names: { ["timeline"] = {"dimensions", "mainFrames", ...}, ... }
local known_fields = {}

-- Extract field names from output lines (patterns like "  .field_name = ...")
local function learn_fields_from_output(query, lines_to_scan)
	local fields = {}
	for _, line in ipairs(lines_to_scan) do
		local field = line:match("^%s*%.([%w_]+)%s*=")
		if field then
			table.insert(fields, field)
		end
	end
	if #fields > 0 then
		known_fields[query] = fields
	end
end

-- Try to learn fields from already-displayed output_lines for a given query
local function try_learn_from_existing_output(query)
	if known_fields[query] then
		return
	end
	-- Look for a ">>> query" line in output_lines, then scan lines after it
	local found_query = false
	local lines_after = {}
	for _, line in ipairs(output_lines) do
		if found_query then
			-- Stop at next >>> or separator
			if line:match("^%s*>>>") or line:match("^─") then
				break
			end
			table.insert(lines_after, line)
		end
		if line:match("^%s*>>> " .. vim.pesc(query) .. "$") then
			found_query = true
		end
	end
	if #lines_after > 0 then
		learn_fields_from_output(query, lines_after)
	end
end

-- Get variable names from current state
local function get_var_names()
	local names = {}
	if current_state and current_state.variables then
		for _, var_line in ipairs(current_state.variables) do
			local name = var_line:match("^%s+(%S+):")
			if name then
				table.insert(names, name)
			end
		end
	end
	return names
end

-- Completion function: called by vim.fn.input
function M.complete(arg_lead)
	local completions = {}
	local function matches(candidate, partial)
		return partial == "" or candidate:lower():find(partial:lower(), 1, true) ~= nil
	end
	local function completion_order(a, b)
		local a_leaf = a:match("([^.]+)$") or a
		local b_leaf = b:match("([^.]+)$") or b
		local partial = arg_lead:match("([^.]+)$") or arg_lead
		local a_starts = a_leaf:sub(1, #partial):lower() == partial:lower()
		local b_starts = b_leaf:sub(1, #partial):lower() == partial:lower()
		if a_starts ~= b_starts then
			return a_starts
		end
		return a < b
	end

	-- Find the last dot to determine prefix vs field
	local last_dot = arg_lead:match(".*()%.")

	if last_dot then
		-- Completing after a dot: "timeline.dim" → look up fields for "timeline"
		local prefix = arg_lead:sub(1, last_dot - 1)
		local partial = arg_lead:sub(last_dot + 1)

		-- Try to learn from existing output first
		try_learn_from_existing_output(prefix)

		-- If still no fields, synchronously query the program and wait
		if not known_fields[prefix] then
			local root = cached_root or get_project_root()
			if root then
				-- Delete old output so we can detect fresh response
				local out_path = root .. "/" .. M.config.output_file
				os.remove(out_path)
				last_output_content = nil

				-- Send query
				send_command(prefix)
				M._last_query = prefix

				-- Wait for fresh output (vim.wait keeps UI responsive)
				vim.wait(1200, function()
					local f = io.open(out_path, "r")
					if not f then
						return false
					end
					local content = f:read("*all")
					f:close()
					if not content or content == "" then
						return false
					end

					-- Got response — parse fields
					local new_lines = {}
					for line in content:gmatch("[^\n]+") do
						table.insert(new_lines, line)
					end
					learn_fields_from_output(prefix, new_lines)

					-- Add to output display
					last_output_content = content
					table.insert(output_lines, ">>> " .. prefix)
					for _, line in ipairs(new_lines) do
						table.insert(output_lines, " " .. line)
					end
					return true
				end, 20)
			end
		end

		local fields = known_fields[prefix]
		if fields then
			for _, field in ipairs(fields) do
				if matches(field, partial) then
					table.insert(completions, prefix .. "." .. field)
				end
			end
		end
	else
		-- Completing variable names
		local vars = get_var_names()
		for _, name in ipairs(vars) do
			if matches(name, arg_lead) then
				table.insert(completions, name)
			end
		end
		-- Also add commands
		for _, cmd in ipairs({ "continue", "step", "next", "out", "quit", "vars", "clear" }) do
			if matches(cmd, arg_lead) then
				table.insert(completions, cmd)
			end
		end
	end

	table.sort(completions, completion_order)
	return completions
end

-- Helper to clear output and delete the file on disk
local function clear_output()
	output_lines = {}
	last_output_content = nil
	inspection = { base = nil, page = 0, total = nil, page_size = 8, paged = false }
	-- Delete the output file so polling doesn't re-add it
	local root = cached_root or get_project_root()
	if root then
		os.remove(root .. "/" .. M.config.output_file)
	end
	if M._render then
		M._render()
	end
end

local function queue_inspection_command(expression)
	inspection_request_id = inspection_request_id + 1
	local request_id = inspection_request_id
	local function send_when_ready(attempts)
		if request_id ~= inspection_request_id then
			return
		end
		local root = cached_root or get_project_root()
		local command_path = root .. "/" .. M.config.command_file
		if vim.fn.filereadable(command_path) == 0 then
			send_command(expression)
		elseif attempts > 0 then
			vim.defer_fn(function()
				send_when_ready(attempts - 1)
			end, 10)
		else
			-- A stale command must not make the inspector appear permanently stuck.
			send_command(expression)
		end
	end
	-- onBreak writes the stopped state just before clearing its old command file.
	-- One short deferred turn closes that race without making the UI feel latent.
	vim.defer_fn(function()
		send_when_ready(100)
	end, 10)
end

local function send_inspection(expression, keep_page)
	if not expression or expression == "" then
		return
	end
	local root = cached_root or get_project_root()
	os.remove(root .. "/" .. M.config.output_file)
	last_output_content = nil
	output_lines = { ">>> " .. expression }
	M._last_query = expression:gsub("%[%d+%.%.%d+%]$", "")
	if not keep_page then
		inspection.base = M._last_query
		inspection.page = 0
		inspection.total = nil
		inspection.paged = false
	end
	if M._render then
		M._render()
	end
	queue_inspection_command(expression)
end

local function send_inspection_page(page)
	if not inspection.base or not inspection.total then
		return
	end
	local pages = math.max(1, math.ceil(inspection.total / inspection.page_size))
	inspection.page = math.max(0, math.min(page, pages - 1))
	inspection.paged = true
	local first = inspection.page * inspection.page_size
	local last = math.min(first + inspection.page_size, inspection.total)
	send_inspection(string.format("%s[%d..%d]", inspection.base, first, last), true)
end

local function prompt_and_send()
	-- Register the completion function in vimscript (once)
	vim.cmd([[
        if !exists('*ZdbComplete')
            function! ZdbComplete(ArgLead, CmdLine, CursorPos)
                return luaeval('require("zdb").complete(_A)', a:ArgLead)
            endfunction
        endif
    ]])

	-- Use vim.fn.input with tab completion
	local ok, input = pcall(vim.fn.input, {
		prompt = "zdb> ",
		completion = "customlist,ZdbComplete",
	})

	if ok and input and input ~= "" then
		-- Handle clear locally (don't send to program)
		if input == "clear" or input == "cls" then
			clear_output()
			return
		end

		send_inspection(input)
	end
end

-- ============================================================================
-- State/output parsing
-- ============================================================================

local function parse_state(content)
	local state = { variables = {} }
	local in_vars = false

	for line in content:gmatch("[^\n]+") do
		if line == "---" then
			in_vars = true
		elseif in_vars then
			table.insert(state.variables, line)
		else
			local key, val = line:match("^(%w+)=(.+)$")
			if key then
				state[key] = val
			end
		end
	end
	return state
end

-- ============================================================================
-- Syntax highlighting
-- ============================================================================

local function highlight_panel(lines)
	if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then
		return
	end

	vim.api.nvim_buf_clear_namespace(panel_buf, hl_ns, 0, -1)

	for i, line in ipairs(lines) do
		local row = i - 1

		-- Status lines
		if line:match("⏸  STOPPED") then
			vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
				end_col = #line,
				hl_group = "ZdbStopped",
			})
		elseif line:match("▶  RUNNING") then
			vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
				end_col = #line,
				hl_group = "ZdbRunning",
			})
		elseif line:match("○  WAITING") then
			vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
				end_col = #line,
				hl_group = "ZdbWaiting",
			})

		-- Section headers / separator lines
		elseif line:match("^── .+ ─") then
			vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
				end_col = #line,
				hl_group = "ZdbHeader",
			})
		elseif line:match("^─+$") then
			vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
				end_col = #line,
				hl_group = "ZdbSeparator",
			})
		elseif line:match("^hint%s+") then
			vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
				end_col = #line,
				hl_group = "ZdbHelpText",
			})

		-- Section headers
		elseif line:match("^ Variables:") or line:match("^ Output:") then
			vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
				end_col = #line,
				hl_group = "ZdbHeader",
			})

		-- Info labels: "  File: ...", "  Line: ...", "  Func: ..."
		elseif
			line:match("^  File:")
			or line:match("^  Line:")
			or line:match("^  Func:")
			or line:match("^file%s+")
			or line:match("^line%s+")
		then
			local colon_pos = line:find(":")
			if colon_pos then
				vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
					end_col = colon_pos,
					hl_group = "ZdbLabel",
				})
				vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, colon_pos, {
					end_col = #line,
					hl_group = "ZdbValue",
				})
			end

		-- A selected byte range or array range. Text ranges render their value
		-- after ` = `, so highlight them like ordinary strings.
		elseif line:match("^%s*%[%d+%.%.%d+%]") then
			local bracket_end = line:find("%]")
			if bracket_end then
				vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
					end_col = bracket_end,
					hl_group = "ZdbLabel",
				})
				local equals = line:find(" = ", bracket_end, true)
				if equals then
					highlight_value(row, equals + 2, line:sub(equals + 3))
				end
			end

		-- Button/help rows
		elseif (surface_rows[i] and surface_rows[i].kind == "buttons") or line:match("^%[") then
			local pos = 1
			while true do
				local s, e = line:find("%b[]", pos)
				if not s then
					break
				end
				vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, s - 1, {
					end_col = e,
					hl_group = "ZdbHelpKey",
				})
				pos = e + 1
			end

		-- Rows in a compact inspection table.
		elseif surface_rows[i] and surface_rows[i].kind == "table-row" then
			local colon = line:find(":")
			if colon then
				vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
					end_col = colon,
					hl_group = "ZdbVarName",
				})
				vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, colon, {
					end_col = #line,
					hl_group = "ZdbValue",
				})
			end

		-- >>> prompt lines
		elseif line:match("^%s*>>>") then
			vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
				end_col = #line,
				hl_group = "ZdbPrompt",
			})

		-- Variable lines: "  name: Type = value"
		elseif line:match("^%s*%S+:%s") then
			local indent_end = #(line:match("^(%s+)") or "")
			local colon_pos = line:find(":", indent_end + 1)
			local eq_pos = line:find(" = ", indent_end + 1)

			if colon_pos then
				-- Variable name (blue)
				vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, indent_end, {
					end_col = colon_pos - 1,
					hl_group = "ZdbVarName",
				})

				if eq_pos then
					-- Type string between : and =
					local type_str = line:sub(colon_pos + 2, eq_pos - 1)
					local type_start = colon_pos + 1 -- +1 for the space after :
					highlight_type(row, type_start, type_str)

					-- Value part
					local val_start = eq_pos + 3
					local val_text = line:sub(val_start)
					highlight_value(row, val_start - 1, val_text)
				else
					-- Just type, no =
					local type_str = line:sub(colon_pos + 2)
					highlight_type(row, colon_pos + 1, type_str)
				end
			end

		-- Output lines with .field = value patterns
		elseif line:match("^%s+%.%w+") then
			local dot_start = line:find("%.")
			if dot_start then
				local eq_pos = line:find(" = ", dot_start)
				if eq_pos then
					vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, dot_start - 1, {
						end_col = eq_pos,
						hl_group = "ZdbFieldName",
					})
					local val_start = eq_pos + 3
					local val_text = line:sub(val_start)
					highlight_value(row, val_start - 1, val_text)
				else
					vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, dot_start - 1, {
						end_col = #line,
						hl_group = "ZdbFieldName",
					})
				end
			end

		-- Output lines with [N] array index
		elseif line:match("^%s+%[%d+%]") then
			local bracket_end = line:find("%]")
			if bracket_end then
				vim.api.nvim_buf_set_extmark(panel_buf, hl_ns, row, 0, {
					end_col = bracket_end,
					hl_group = "ZdbLabel",
				})
				local val_text = line:sub(bracket_end + 2)
				if #val_text > 0 then
					highlight_value(row, bracket_end + 1, val_text)
				end
			end
		end
	end
end

-- The live debugger prefixes returned lines with one space when appending them
-- to output_lines. Remove only that transport prefix; the remaining indentation
-- describes the value tree and is used to make nested rows navigable.
local function inspection_text(line)
	if line:sub(1, 1) == " " then
		return line:sub(2)
	end
	return line
end

local function nearest_parent(paths, indent, fallback)
	local best_indent = -1
	local best = fallback
	for path_indent, path in pairs(paths) do
		if path_indent < indent and path_indent > best_indent then
			best_indent = path_indent
			best = path
		end
	end
	return best
end

-- Turn a flat slice of simple structs into the same compact, column-oriented
-- table used by the terminal debugger. Nested values fall back to the tree view.
local function table_inspection_entries(entries, width)
	local first, last
	local items = {}
	local i = 1
	while i <= #entries do
		local text = entries[i].text
		local indent, index = text:match("^(%s*)%[(%d+)%]%s+.-{%s*$")
		if indent and index then
			local fields = {}
			local j = i + 1
			local ok = false
			while j <= #entries do
				local row = entries[j].text
				if row:match("^" .. indent .. "}%s*$") then
					ok = #fields > 0
					break
				end
				local name, value = row:match("^%s+%.([%w_]+)%s*=%s*(.-)%s*$")
				if not name or value:match("[{%[]%s*$") then
					ok = false
					break
				end
				fields[#fields + 1] = { name = name, value = value }
				j = j + 1
			end
			if ok then
				first = first or i
				last = j
				items[#items + 1] = {
					index = tonumber(index),
					fields = fields,
					expression = inspection.base and string.format("%s[%s]", inspection.base, index)
						or (entries[i].action and entries[i].action.expression or nil),
				}
				i = j + 1
			else
				i = i + 1
			end
		else
			i = i + 1
		end
	end

	if #items < 2 or not first or not last then
		return entries
	end
	local field_names = {}
	for _, field in ipairs(items[1].fields) do
		field_names[#field_names + 1] = field.name
	end
	for _, item in ipairs(items) do
		if #item.fields ~= #field_names then
			return entries
		end
		for field_index, name in ipairs(field_names) do
			if item.fields[field_index].name ~= name then
				return entries
			end
		end
	end

	local label_width = 0
	for _, name in ipairs(field_names) do
		label_width = math.max(label_width, #name + 1)
	end
	local available = math.max(8, width - label_width - 1)
	local column_width = math.max(5, math.min(18, math.floor(available / #items)))
	local function cell(value)
		if #value > column_width - 1 then
			value = value:sub(1, math.max(1, column_width - 2)) .. "…"
		end
		return value .. string.rep(" ", math.max(1, column_width - #value))
	end

	local replacement = {}
	local header = string.rep(" ", label_width + 1)
	local buttons = {}
	for _, item in ipairs(items) do
		local label = "[" .. item.index .. "]"
		local start_col = #header
		header = header .. cell(label)
		buttons[#buttons + 1] = {
			first = start_col,
			last = #header,
			expression = item.expression,
		}
	end
	replacement[#replacement + 1] = { text = header, action = { kind = "buttons", buttons = buttons } }
	for field_index, name in ipairs(field_names) do
		local row = name .. ":" .. string.rep(" ", label_width - #name)
		for _, item in ipairs(items) do
			row = row .. cell(item.fields[field_index].value)
		end
		replacement[#replacement + 1] = { text = row, action = { kind = "table-row" } }
	end

	local result = {}
	for entry_index = 1, first - 1 do
		result[#result + 1] = entries[entry_index]
	end
	for _, entry in ipairs(replacement) do
		result[#result + 1] = entry
	end
	for entry_index = last + 1, #entries do
		result[#result + 1] = entries[entry_index]
	end
	return result
end

local function inspection_entries(width)
	local entries = {}
	local paths = {}
	for _, output_line in ipairs(output_lines) do
		local text = inspection_text(output_line)
		local action = nil
		local indent_text = text:match("^(%s*)") or ""
		local indent = #indent_text
		local field, value = text:match("^%s*%.([%w_]+)%s*=%s*(.-)%s*$")
		local index, index_value = text:match("^%s*%[(%d+)%]%s*(.-)%s*$")
		local parent = nearest_parent(paths, indent, inspection.base)

		if field and parent then
			local expression = parent .. "." .. field
			action = { kind = "inspect-expression", expression = expression }
			if value:match("[{%[]%s*$") or value:match("^%[%]%(%d+ items%)") then
				paths[indent] = expression
			end
		elseif index and parent then
			local expression = string.format("%s[%s]", parent, index)
			action = { kind = "inspect-expression", expression = expression }
			if index_value:match("[{%[]%s*$") then
				paths[indent] = expression
			end
		elseif text:match("^%s*>>>") and inspection.base then
			action = { kind = "inspect-expression", expression = inspection.base }
		end
		entries[#entries + 1] = { text = text, action = action }
	end
	return table_inspection_entries(entries, width)
end

-- Highlight a type string like "*timeline.AnimationTimeline" or "usize"
-- Sigils (*, []) → gray, module path → gray, final type name → purple
function highlight_type(row, col, type_str)
	if not panel_buf or #type_str == 0 then
		return
	end

	local pos = col
	local i = 1

	-- Skip and highlight leading sigils: *, ?, [], *const, etc.
	while i <= #type_str do
		local ch = type_str:sub(i, i)
		if ch == "*" or ch == "?" or ch == "[" or ch == "]" then
			pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos, {
				end_col = pos + 1,
				hl_group = "ZdbTypeSigil",
			})
			pos = pos + 1
			i = i + 1
		elseif type_str:sub(i, i + 5) == "const " then
			pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos, {
				end_col = pos + 5,
				hl_group = "ZdbTypeSigil",
			})
			pos = pos + 6
			i = i + 6
		else
			break
		end
	end

	-- Remaining is the type path like "timeline.AnimationTimeline" or "usize"
	local rest = type_str:sub(i)
	local last_dot = rest:match(".*()%.")

	if last_dot then
		-- Module path before last dot → gray
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos, {
			end_col = pos + last_dot,
			hl_group = "ZdbTypeModule",
		})
		-- Final type name after last dot → purple
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos + last_dot, {
			end_col = pos + #rest,
			hl_group = "ZdbTypeName",
		})
	else
		-- Simple type like "usize", "bool" → purple
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, pos, {
			end_col = pos + #rest,
			hl_group = "ZdbTypeName",
		})
	end
end

-- Highlight a value string at a given position
function highlight_value(row, col, text)
	if not panel_buf then
		return
	end

	-- String values
	if text:match('^"') then
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
			end_col = col + #text,
			hl_group = "ZdbString",
		})
	-- null, true, false
	elseif text == "null" or text == "true" or text == "false" then
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
			end_col = col + #text,
			hl_group = "ZdbKeyword",
		})
	-- Enum .tag
	elseif text:match("^%.%w") then
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
			end_col = col + #text,
			hl_group = "ZdbEnum",
		})
	-- <fn>
	elseif text == "<fn>" then
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
			end_col = col + #text,
			hl_group = "ZdbFn",
		})
	-- ptr
	elseif text == "ptr" then
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
			end_col = col + #text,
			hl_group = "ZdbPtr",
		})
	-- Numbers
	elseif text:match("^%-?%d") then
		pcall(vim.api.nvim_buf_set_extmark, panel_buf, hl_ns, row, col, {
			end_col = col + #text,
			hl_group = "ZdbNumber",
		})
	end
end

-- ============================================================================
-- Panel rendering
-- ============================================================================

function M._render()
	if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then
		return
	end
	if inspector_editing then
		return
	end

	local lines = {}
	local rows = {}
	local state = current_state or {}
	local width =
		math.max(46, vim.api.nvim_win_is_valid(panel_win or -1) and vim.api.nvim_win_get_width(panel_win) - 1 or 46)
	local function push(text, action)
		lines[#lines + 1] = text
		rows[#lines] = action
	end
	local function rule(title)
		if title then
			local prefix = "── " .. title .. " "
			push(prefix .. string.rep("─", math.max(0, width - vim.fn.strdisplaywidth(prefix))), nil)
		else
			push(string.rep("─", width), nil)
		end
	end
	local function button_row(specs)
		local text = ""
		local buttons = {}
		for _, spec in ipairs(specs) do
			if #text > 0 then
				text = text .. " "
			end
			local first = #text
			text = text .. spec[1]
			buttons[#buttons + 1] = { first = first, last = #text, command = spec[2] }
		end
		push(text, { kind = "buttons", buttons = buttons })
	end

	if state.status == "stopped" then
		push("⏸  STOPPED  " .. (state["function"] or "?") .. "()", { kind = "location" })
		button_row({
			{ "[Continue]", "continue" },
			{ "[Step]", "step" },
			{ "[Next]", "next" },
			{ "[Out]", "out" },
			{ "[Quit]", "quit" },
		})
		rule()
		push(string.format("file      %s", state.file or "?"), { kind = "location" })
		push(string.format("line      %s", state.line or "?"), { kind = "location" })
		push("", nil)

		rule("variables")
		if #state.variables > 0 then
			for _, var_line in ipairs(state.variables) do
				local name = var_line:match("^%s*(%S+):")
				push(var_line:gsub("^%s+", ""), name and { kind = "variable", expression = name } or nil)
			end
		else
			push("(none)", nil)
		end

		push("", nil)
		rule("inspection")
		inspector_line = #lines + 1
		push("inspect > " .. (inspection.base or ""), { kind = "inspector" })
		push("hint      click a field or [index] to inspect deeper", nil)
		if inspection.total then
			local pages = math.max(1, math.ceil(inspection.total / inspection.page_size))
			button_row({
				{ "[Prev page]", "page-prev" },
				{ string.format("[Page %d/%d]", inspection.page + 1, pages), "page-current" },
				{ "[Next page]", "page-next" },
			})
		end
		if #output_lines > 0 then
			for _, entry in ipairs(inspection_entries(width)) do
				push(entry.text, entry.action)
			end
		else
			push("(select a variable or enter an expression)", nil)
		end

		local bp_rows = {}
		for file, file_bps in pairs(breakpoints) do
			for line, enabled in pairs(file_bps) do
				if enabled then
					bp_rows[#bp_rows + 1] = { file = file, line = line }
				end
			end
		end
		table.sort(bp_rows, function(a, b)
			return a.file == b.file and a.line < b.line or a.file < b.file
		end)
		if #bp_rows > 0 then
			push("", nil)
			rule("breakpoints")
			for _, bp in ipairs(bp_rows) do
				local rel = relative_path(bp.file, cached_root or get_project_root())
				push(string.format("● %s:%d", rel, bp.line), { kind = "breakpoint", file = bp.file, line = bp.line })
			end
		end

		push("", nil)
		rule("keys")
		push("[Click/Enter] activate   [i/p] inspector   [g] source", nil)
		push("[Tab/S-Tab] complete/next match   [/] search panel", nil)
		push("[[ / ]] previous/next data page   [x] clear", nil)
		button_row({
			{ "[c] continue", "continue" },
			{ "[s] step", "step" },
			{ "[n] next", "next" },
			{ "[o] out", "out" },
			{ "[r] reload", "reload" },
			{ "[q] quit", "quit" },
		})
	elseif state.status == "running" then
		push("▶  RUNNING", nil)
		rule()
		push("The program is running. Breakpoints remain live.", nil)
		push("Use <leader>db in instrumented Zig code to add or remove one.", nil)
		output_lines = {}
	else
		push("○  WAITING", nil)
		rule()
		push("Run `zig build debug`, then use this buffer as the debugger surface.", nil)
		push("Only files selected by the debug build can stop live execution.", nil)
	end

	local win = vim.fn.bufwinid(panel_buf)
	local cursor = win ~= -1 and vim.api.nvim_win_get_cursor(win) or nil
	vim.bo[panel_buf].modifiable = true
	vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
	vim.bo[panel_buf].modifiable = false
	vim.bo[panel_buf].modified = false
	surface_rows = rows
	if cursor and #lines > 0 then
		pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(cursor[1], #lines)), cursor[2] })
	end
	highlight_panel(lines)
end

-- ============================================================================
-- Polling
-- ============================================================================

local function poll_state()
	if not cached_root then
		return
	end

	local state_path = cached_root .. "/" .. M.config.state_file
	local sf = io.open(state_path, "r")
	if sf then
		local content = sf:read("*all")
		sf:close()

		if content ~= last_state_content then
			last_state_content = content
			local state = parse_state(content)

			vim.schedule(function()
				local newly_stopped = state.status == "stopped"
					and (
						not current_state
						or current_state.status ~= "stopped"
						or current_state.line ~= state.line
						or current_state.file ~= state.file
					)
				local same_function = current_state
					and current_state["function"] == state["function"]
					and current_state.file == state.file
				if newly_stopped then
					output_lines = {}
					last_output_content = nil
					known_fields = {}
					M._last_query = nil
					-- A watch path means something else in another function (same name, other type): drop it there
					if not same_function then
						inspection = { base = nil, page = 0, total = nil, page_size = 8, paged = false }
					end
				end

				current_state = state
				if newly_stopped then
					goto_stopped_source(false)
					mark_stopped_line()
					vim.notify(string.format("zdb stopped at %s:%s", state.file or "?", state.line or "?"))
					if M.config.open_on_stop and M.open_stop_surface then
						M.open_stop_surface()
					end
					-- Treat the inspector like a watch expression within one function. The stopped
					-- state is written just before the runtime clears its old command file, so
					-- send_inspection queues the refresh until that reset is complete.
					if inspection.base then
						send_inspection(inspection.base)
					end
				end
				M._render()
			end)
		end
	else
		if last_state_content ~= nil then
			last_state_content = nil
			vim.schedule(function()
				current_state = { status = "waiting" }
				M._render()
			end)
		end
	end

	local out_path = cached_root .. "/" .. M.config.output_file
	local of = io.open(out_path, "r")
	if of then
		local content = of:read("*all")
		of:close()

		if content and content ~= "" and content ~= last_output_content then
			last_output_content = content
			vim.schedule(function()
				local new_lines = {}
				for line in content:gmatch("[^\n]+") do
					table.insert(output_lines, " " .. line)
					table.insert(new_lines, line)
				end

				-- Learn field names from this output for tab completion
				if M._last_query then
					learn_fields_from_output(M._last_query, new_lines)
				end

				local total = tonumber(content:match("\n%[%]%((%d+) items%)"))
				if total and total > inspection.page_size and inspection.base and not inspection.paged then
					inspection.total = total
					local function first_page_when_ready(attempts)
						local command_path = cached_root .. "/" .. M.config.command_file
						if vim.fn.filereadable(command_path) == 0 then
							send_inspection_page(0)
						elseif attempts > 0 then
							vim.defer_fn(function()
								first_page_when_ready(attempts - 1)
							end, 20)
						end
					end
					first_page_when_ready(20)
				end

				M._render()
			end)
		end
	end
end

-- ============================================================================
-- Panel management
-- ============================================================================

local function goto_location(file, line, create_window)
	local target = file
	if target:sub(1, 1) ~= "/" then
		target = (cached_root or get_project_root()) .. "/" .. target
	end
	local win = source_window()
	if not win and create_window then
		vim.cmd("split " .. vim.fn.fnameescape(target))
		win = vim.api.nvim_get_current_win()
	end
	if not win then
		return
	end
	local buf = vim.fn.bufnr(target)
	if buf == -1 then
		vim.api.nvim_win_call(win, function()
			vim.cmd("edit " .. vim.fn.fnameescape(target))
		end)
	else
		vim.api.nvim_win_set_buf(win, buf)
	end
	pcall(vim.api.nvim_win_set_cursor, win, { tonumber(line) or 1, 0 })
	vim.api.nvim_set_current_win(win)
	update_signs(vim.api.nvim_win_get_buf(win))
	mark_stopped_line()
end

local inspector_prefix = "inspect > "

local function finish_inspector_edit()
	if not inspector_editing or not inspector_line then
		return
	end
	local line = vim.api.nvim_buf_get_lines(panel_buf, inspector_line - 1, inspector_line, false)[1] or ""
	local expression = vim.trim(line:sub(#inspector_prefix + 1))
	inspector_editing = false
	inspector_snapshot = nil
	vim.cmd("stopinsert")
	vim.bo[panel_buf].modifiable = false
	vim.bo[panel_buf].modified = false
	if expression ~= "" then
		send_inspection(expression)
	else
		M._render()
	end
end

local function cancel_inspector_edit()
	if not inspector_editing then
		return
	end
	inspector_editing = false
	inspector_snapshot = nil
	vim.cmd("stopinsert")
	vim.bo[panel_buf].modifiable = false
	vim.bo[panel_buf].modified = false
	M._render()
end

local function protect_inspector_surface()
	if not inspector_editing or inspector_guarding or not inspector_snapshot or not inspector_line then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
	local valid = #lines == #inspector_snapshot
	if valid then
		for index, original in ipairs(inspector_snapshot) do
			if index ~= inspector_line and lines[index] ~= original then
				valid = false
				break
			end
		end
	end
	local edited = lines[inspector_line]
	if valid and edited and edited:sub(1, #inspector_prefix) == inspector_prefix then
		return
	end

	inspector_guarding = true
	vim.schedule(function()
		if inspector_editing and inspector_snapshot and vim.api.nvim_buf_is_valid(panel_buf) then
			local restored = vim.deepcopy(inspector_snapshot)
			local expression = ""
			if edited and edited:sub(1, #inspector_prefix) == inspector_prefix then
				expression = edited:sub(#inspector_prefix + 1):gsub("[\r\n]", "")
			end
			restored[inspector_line] = inspector_prefix .. expression
			vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, restored)
			local win = vim.fn.bufwinid(panel_buf)
			if win ~= -1 then
				vim.api.nvim_win_set_cursor(win, { inspector_line, #(inspector_prefix .. expression) })
			end
		end
		inspector_guarding = false
	end)
end

local function inspector_complete()
	if vim.fn.pumvisible() == 1 then
		return "<C-n>"
	end
	local line = vim.api.nvim_get_current_line()
	local expression = line:sub(#inspector_prefix + 1)
	local choices = M.complete(expression)
	if #choices > 0 then
		local complete_col = #inspector_prefix + 1
		local expected_buf = panel_buf
		-- Neovim forbids changing text or windows while an expression mapping is
		-- being evaluated (E565). Open the completion menu immediately after the
		-- mapping returns instead.
		vim.schedule(function()
			if
				expected_buf
				and vim.api.nvim_buf_is_valid(expected_buf)
				and vim.api.nvim_get_current_buf() == expected_buf
				and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
			then
				pcall(vim.fn.complete, complete_col, choices)
			end
		end)
	end
	return ""
end

local function start_inspector_edit()
	if not inspector_line or not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then
		return
	end
	local win = vim.fn.bufwinid(panel_buf)
	if win == -1 then
		return
	end
	panel_win = win
	vim.api.nvim_set_current_win(win)
	inspector_editing = true
	vim.bo[panel_buf].modifiable = true
	local initial = inspector_prefix .. (inspection.base or "")
	vim.api.nvim_buf_set_lines(panel_buf, inspector_line - 1, inspector_line, false, { initial })
	inspector_snapshot = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
	vim.api.nvim_win_set_cursor(win, { inspector_line, #initial })
	vim.cmd("startinsert!")
end

local function run_panel_command(command)
	if command == "page-prev" then
		send_inspection_page(inspection.page - 1)
	elseif command == "page-next" then
		send_inspection_page(inspection.page + 1)
	elseif command ~= "page-current" then
		send_command(command)
	end
end

function M.activate()
	local action = surface_rows[vim.fn.line(".")]
	if not action then
		return
	end
	if action.kind == "variable" then
		send_inspection(action.expression)
	elseif action.kind == "location" then
		goto_stopped_source(true)
	elseif action.kind == "breakpoint" then
		goto_location(action.file, action.line, true)
	elseif action.kind == "inspector" then
		start_inspector_edit()
	elseif action.kind == "inspect-expression" then
		send_inspection(action.expression)
	elseif action.kind == "buttons" then
		local col = vim.api.nvim_win_get_cursor(0)[2]
		for _, button in ipairs(action.buttons) do
			if col >= button.first and col < button.last then
				if button.expression then
					send_inspection(button.expression)
				elseif button.command then
					run_panel_command(button.command)
				end
				break
			end
		end
	end
end

local function delete_breakpoint_row()
	local action = surface_rows[vim.fn.line(".")]
	if not action or action.kind ~= "breakpoint" then
		vim.notify("zdb: put the cursor on a breakpoint row", vim.log.levels.WARN)
		return
	end
	if breakpoints[action.file] then
		breakpoints[action.file][action.line] = nil
		if not next(breakpoints[action.file]) then
			breakpoints[action.file] = nil
		end
	end
	write_breakpoints_zon(cached_root or get_project_root())
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			update_signs(buf)
		end
	end
	M._render()
end

local function setup_panel_keymaps()
	if not panel_buf then
		return
	end

	local opts = { buffer = panel_buf, nowait = true, silent = true }
	vim.keymap.set("n", "c", function()
		send_command("continue")
	end, opts)
	vim.keymap.set("n", "s", function()
		send_command("step")
	end, opts)
	vim.keymap.set("n", "n", function()
		send_command("next")
	end, opts)
	vim.keymap.set("n", "o", function()
		send_command("out")
	end, opts)
	vim.keymap.set("n", "q", function()
		send_command("quit")
	end, opts)
	vim.keymap.set("n", "p", start_inspector_edit, opts)
	vim.keymap.set("n", "i", start_inspector_edit, opts)
	vim.keymap.set("n", "P", prompt_and_send, opts)
	vim.keymap.set("n", "v", function()
		send_command("v")
	end, opts)
	vim.keymap.set("n", "<CR>", M.activate, opts)
	vim.keymap.set("n", "g", function()
		goto_stopped_source(true)
	end, opts)
	vim.keymap.set("n", "dd", delete_breakpoint_row, opts)
	vim.keymap.set("n", "x", clear_output, opts)
	vim.keymap.set("n", "r", function()
		send_command("reload")
	end, opts)
	vim.keymap.set("n", "[", function()
		send_inspection_page(inspection.page - 1)
	end, opts)
	vim.keymap.set("n", "]", function()
		send_inspection_page(inspection.page + 1)
	end, opts)
	-- Activate after mouse release so Neovim keeps ownership of click-drag on the
	-- split separator. This makes the panel width directly draggable.
	vim.keymap.set("n", "<LeftRelease>", function()
		local mouse = vim.fn.getmousepos()
		if mouse.winid ~= panel_win or mouse.line < 1 then
			return
		end
		vim.api.nvim_set_current_win(panel_win)
		vim.api.nvim_win_set_cursor(panel_win, { mouse.line, math.max(0, mouse.column - 1) })
		M.activate()
	end, opts)

	local insert_opts = { buffer = panel_buf, nowait = true, silent = true }
	vim.keymap.set("i", "<CR>", finish_inspector_edit, insert_opts)
	vim.keymap.set("i", "<Esc>", cancel_inspector_edit, insert_opts)
	vim.keymap.set("i", "<Tab>", inspector_complete, { buffer = panel_buf, nowait = true, silent = true, expr = true })
	vim.keymap.set("i", "<S-Tab>", function()
		return vim.fn.pumvisible() == 1 and "<C-p>" or "<S-Tab>"
	end, { buffer = panel_buf, nowait = true, silent = true, expr = true })
end

local function attach_surface(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	panel_buf = buf
	panel_win = vim.api.nvim_get_current_win()
	vim.bo[buf].filetype = "zdb"
	vim.bo[buf].modifiable = false
	vim.bo[buf].swapfile = false
	vim.bo[buf].undofile = false
	vim.bo[buf].bufhidden = "hide"
	if panel_win and vim.api.nvim_win_is_valid(panel_win) then
		vim.wo[panel_win].number = false
		vim.wo[panel_win].relativenumber = false
		vim.wo[panel_win].signcolumn = "no"
		vim.wo[panel_win].wrap = false
		vim.wo[panel_win].cursorline = true
		vim.wo[panel_win].winfixwidth = false
	end

	vim.api.nvim_clear_autocmds({
		group = augroup,
		buffer = buf,
		event = { "BufWriteCmd", "InsertLeave", "BufLeave", "TextChangedI" },
	})
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		group = augroup,
		callback = function()
			vim.bo[buf].modified = false
		end,
	})
	vim.api.nvim_create_autocmd("TextChangedI", {
		buffer = buf,
		group = augroup,
		callback = protect_inspector_surface,
	})
	vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
		buffer = buf,
		group = augroup,
		callback = function()
			if not inspector_editing then
				return
			end
			inspector_editing = false
			inspector_snapshot = nil
			vim.bo[buf].modifiable = false
			vim.bo[buf].modified = false
			vim.schedule(M._render)
		end,
	})

	setup_panel_keymaps()
	M._render()
end

function M.is_panel_open()
	return panel_buf and vim.api.nvim_buf_is_valid(panel_buf) and vim.fn.bufwinid(panel_buf) ~= -1
end

function M.open_panel()
	if M.is_panel_open() then
		panel_win = vim.fn.bufwinid(panel_buf)
		vim.api.nvim_set_current_win(panel_win)
		return
	end
	if not panel_buf or not vim.api.nvim_buf_is_valid(panel_buf) then
		panel_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(panel_buf, "[zdb]")
	end
	vim.cmd("botright vsplit")
	panel_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(panel_win, panel_buf)
	vim.api.nvim_win_set_width(panel_win, M.config.panel_width)
	attach_surface(panel_buf)
end

function M.open_stop_surface()
	if M.is_panel_open() then
		return
	end
	local source_win = vim.api.nvim_get_current_win()
	M.open_panel()
	if vim.api.nvim_win_is_valid(source_win) then
		vim.api.nvim_set_current_win(source_win)
	end
end

function M.close_panel()
	if M.is_panel_open() then
		local win = vim.fn.bufwinid(panel_buf)
		vim.api.nvim_win_close(win, true)
	end
	panel_win = nil
end

function M.toggle_panel()
	if M.is_panel_open() then
		M.close_panel()
	else
		M.open_panel()
	end
end

function M.start_polling()
	if poll_timer then
		return
	end

	poll_timer = vim.loop.new_timer()
	poll_timer:start(0, M.config.poll_ms, function()
		poll_state()
	end)
end

function M.stop_polling()
	if poll_timer then
		poll_timer:stop()
		poll_timer:close()
		poll_timer = nil
	end
	last_state_content = nil
	last_output_content = nil
end

-- ============================================================================
-- Setup
-- ============================================================================

local function user_command(name, callback, opts)
	pcall(vim.api.nvim_del_user_command, name)
	vim.api.nvim_create_user_command(name, callback, opts or {})
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	cached_root = get_project_root()
	load_breakpoints_zon(cached_root)
	augroup = vim.api.nvim_create_augroup("zdb", { clear = true })

	setup_highlights()

	local keys = M.config.keys
	local function map(name, fn, desc)
		local lhs = keys and keys[name]
		if lhs then
			vim.keymap.set("n", lhs, fn, { desc = "zdb: " .. desc })
		end
	end
	map("toggle_breakpoint", toggle_breakpoint, "toggle breakpoint")
	map("panel", M.toggle_panel, "open debug surface")
	map("continue", function()
		send_command("continue")
	end, "continue")
	map("step", function()
		send_command("step")
	end, "step in")
	map("next", function()
		send_command("next")
	end, "step over")
	map("out", function()
		send_command("out")
	end, "step out")
	map("quit", function()
		send_command("quit")
	end, "quit debuggee")
	map("clear", clear_output, "clear output")

	if M.config.gutter_click then
		vim.keymap.set("n", "<LeftMouse>", source_gutter_click, {
			expr = true,
			silent = true,
			desc = "zdb: click Zig gutter to toggle breakpoint",
		})
	end

	user_command("ZdbToggle", toggle_breakpoint)
	user_command("Zdb", M.open_panel)
	user_command("ZdbPanel", M.toggle_panel)
	user_command("ZdbContinue", function()
		send_command("continue")
	end)
	user_command("ZdbStep", function()
		send_command("step")
	end)
	user_command("ZdbNext", function()
		send_command("next")
	end)
	user_command("ZdbOut", function()
		send_command("out")
	end)
	user_command("ZdbQuit", function()
		send_command("quit")
	end)
	user_command("ZdbClear", clear_output)
	user_command("ZdbPrint", function(a)
		if a.args and a.args ~= "" then
			send_inspection(a.args)
		else
			prompt_and_send()
		end
	end, { nargs = "?" })

	vim.api.nvim_create_autocmd("BufEnter", {
		group = augroup,
		pattern = "*.zig",
		callback = function(ev)
			update_signs(ev.buf)
			mark_stopped_line()
		end,
	})

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWinEnter", "BufEnter" }, {
		group = augroup,
		pattern = "*.zdb",
		callback = function(ev)
			attach_surface(ev.buf)
		end,
	})

	M.start_polling()

	if vim.api.nvim_buf_get_name(0):match("%.zdb$") then
		attach_surface(vim.api.nvim_get_current_buf())
	end
end

return M
