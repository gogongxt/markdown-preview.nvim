-- lua/markdown_preview/init.lua
local ts = require("markdown_preview.ts")
local util = require("markdown_preview.util")
local ls_server = require("live_server.server")
local ls_util = require("live_server.util")

local M = {}

M.config = {
	port = 0, -- 0 = auto; effective port depends on instance_mode
	host = "127.0.0.1", -- bind address; "0.0.0.0" for network access (e.g. over SSH)
	open_browser = true,

	-- nil = system default browser. String for app/binary name (e.g. "Firefox",
	-- "google-chrome"). Table for full command with args (URL is appended).
	-- On macOS, string values are passed via `open -a <name>`.
	browser = nil,

	-- "takeover" = shared workspace + fixed port, one browser tab across instances
	-- "multi" = per-instance server + browser tab (port 0 recommended)
	instance_mode = "takeover",

	content_name = "content.md",
	-- Workspace file written for HTML-buffer previews (ft == "html").
	-- Served token-gated like content.md; see html_sandbox below.
	html_content_name = "content.html",
	index_name = "index.html",

	-- Path to a CSS file injected after the bundled styles, so user rules win
	-- the cascade without !important. Supports ~ and $VARS. "" = disabled.
	custom_css = "",

	-- nil = per-buffer workspace (recommended); set a path to override
	workspace_dir = nil,

	overwrite_index_on_start = true,

	auto_refresh = true,
	auto_refresh_events = { "InsertLeave", "TextChanged", "TextChangedI", "BufWritePost" },
	debounce_ms = 300,
	notify_on_refresh = false,

	-- "js" = browser-side mermaid.js (default, zero deps)
	-- "rust" = pre-render via mermaid-rs-renderer (mmdr) CLI (~400x faster)
	mermaid_renderer = "js",

	-- Load ELK layout engine for mermaid diagrams (requires internet; adds ~800 KB).
	-- Enables %%{init: {"layout": "elk"}}%% in diagrams.
	mermaid_elk = false,

	scroll_sync = true, -- sync browser scroll to cursor position

	-- "dark" or "light"; determines the initial theme of the preview page
	default_theme = "dark",

	-- Render raw HTML embedded in markdown (GitHub-like). Set false when
	-- previewing untrusted markdown: raw HTML runs inside the preview page.
	allow_raw_html = true,

	-- Preview HTML buffers (ft == "html") in an iframe inside the preview
	-- shell. false (default): the iframe is NOT sandboxed — scripts in the
	-- buffer run same-origin with the preview page (same trust posture as
	-- allow_raw_html = true) and cursor scroll sync works.
	-- true: the iframe gets sandbox="allow-scripts allow-forms allow-popups";
	-- scroll sync is disabled for HTML mode (opaque origin blocks it).
	html_sandbox = false,

	-- YAML front matter (--- ... --- at the top of the file):
	-- "panel" = strip it from the preview, show in a collapsible panel above
	-- "hide"  = strip it entirely
	-- "raw"   = leave it in the document (renders as markdown)
	yaml_mode = "panel",

	-- Fraction (0–1): vertical position of the final line when scrolled to end.
	-- 0.5 = middle of viewport (default), 1.0 = bottom edge (no extra space)
	bottom_padding = 0.5,

	hooks = {
		-- fun(url: string)|nil — called after preview starts; receives the preview URL
		on_start = nil,
		-- fun()|nil — called after preview stops
		on_stop = nil,
	},
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	M.config.bottom_padding = math.max(0, math.min(1, M.config.bottom_padding))
	M._mmdr_available = nil -- reset so next check re-probes
end

-- Internal state
M._augroup = nil
M._active_bufnr = nil
M._last_text_by_buf = {}
M._server_instance = nil
M._debounce_seq = 0
M._workspace_dir = nil
M._mmdr_available = nil -- nil = unchecked, true/false after probe
M._last_scroll_line = nil
M._is_primary = nil      -- true/false/nil (takeover mode)
M._takeover_port = nil   -- port of primary server (secondary uses for HTTP events)
M._token = nil           -- live-server auth token (primary owns; secondaries read from lockfile)

local function effective_port()
	if M.config.port ~= 0 then return M.config.port end
	if M.config.instance_mode == "takeover" then return 8421 end
	return 0
end

local function host_is_loopback()
	return M.config.host == "127.0.0.1" or M.config.host == "localhost"
end

---------------------------------------------------------------------------
-- Workspace
---------------------------------------------------------------------------

local function resolve_workspace(bufnr)
	if M.config.workspace_dir then
		return M.config.workspace_dir
	end
	return util.workspace_for_buffer(bufnr)
end

local function ensure_workspace(bufnr)
	local dir = resolve_workspace(bufnr)
	util.mkdirp(dir)
	return dir
end

---------------------------------------------------------------------------
-- Index HTML
---------------------------------------------------------------------------

local function write_index(dir, source_path, mode)
	local dst = vim.fs.joinpath(dir, M.config.index_name)
	local src = util.resolve_asset("assets/index.html")
	if not src then
		error("Could not locate assets/index.html in runtimepath. Make sure the plugin ships it.")
	end
	local content = util.read_text(src)

	-- gsub with function replacement: avoids the "%n is a capture reference"
	-- escape problem if any substituted value contains '%'.
	content = content:gsub("__BOTTOM_PADDING__", function() return tostring(M.config.bottom_padding) end)
	content = content:gsub("__MERMAID_ELK__", function() return M.config.mermaid_elk and "true" or "false" end)
	-- Anchor to the attribute: index.html also contains the bare placeholder
	-- as a JS sentinel, and substituting that too breaks auth (issue #31).
	-- Bake the token only on loopback binds: on a network bind the index is
	-- served to any peer that can reach the port, and a baked token would
	-- defeat the auth entirely (the browser gets it via ?t= instead).
	content = content:gsub('data%-live%-token="__LIVE_TOKEN__"', function()
		return 'data-live-token="' .. (host_is_loopback() and M._token or "") .. '"'
	end)
	content = content:gsub("__THEME__", function() return M.config.default_theme end)
	content = content:gsub("__ALLOW_HTML__", function()
		return M.config.allow_raw_html ~= false and "true" or "false"
	end)
	content = content:gsub("__YAML_MODE__", function()
		local m = M.config.yaml_mode
		if m ~= "hide" and m ~= "raw" then m = "panel" end
		return m
	end)
	-- Bake the source file's display path so the browser can show it in the
	-- header on first paint, before SSE connects (the 'source' event is only
	-- reliable on retarget, when a client is already listening). HTML-attribute
	-- escape: the value lands inside data-source-path="...".
	local sp = source_path or ""
	sp = sp:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;")
	content = content:gsub('data%-source%-path="__SOURCE_PATH__"', function()
		return 'data-source-path="' .. sp .. '"'
	end)
	-- Preview mode + content filenames for the browser: it dispatches on
	-- data-preview-mode at boot and derives the mode from the reload event's
	-- changed-path basename, so it needs to know both content names.
	content = content:gsub('data%-preview%-mode="__PREVIEW_MODE__"', function()
		return 'data-preview-mode="' .. (mode == "html" and "html" or "md") .. '"'
	end)
	content = content:gsub('data%-html%-sandbox="__HTML_SANDBOX__"', function()
		return 'data-html-sandbox="' .. (M.config.html_sandbox and "true" or "false") .. '"'
	end)
	content = content:gsub('data%-md%-name="__MD_NAME__"', function()
		return 'data-md-name="' .. M.config.content_name .. '"'
	end)
	content = content:gsub('data%-html%-name="__HTML_NAME__"', function()
		return 'data-html-name="' .. M.config.html_content_name .. '"'
	end)

	-- Inline custom CSS after the bundled styles so user rules win the cascade.
	if M.config.custom_css and M.config.custom_css ~= "" then
		local css_src = vim.fn.expand(M.config.custom_css)
		local ok, css = pcall(util.read_text, css_src)
		if ok and css then
			content = content:gsub("</head>", function()
				return "<style>\n" .. css .. "\n</style>\n</head>"
			end, 1)
		else
			vim.notify("Markdown Preview: custom_css not readable: " .. css_src, vim.log.levels.WARN)
		end
	end

	util.write_text(dst, content)
	return dst
end

local function write_index_if_needed(dir, source_path, mode)
	if M.config.overwrite_index_on_start then
		return write_index(dir, source_path, mode)
	end
	local dst = vim.fs.joinpath(dir, M.config.index_name)
	if not util.file_exists(dst) then
		return write_index(dir, source_path, mode)
	end
	-- Rewrite a persisted index whose baked token, source path OR preview
	-- mode no longer matches what this session serves. Covers a fresh token
	-- after restart, a loopback<->network switch (which flips whether the
	-- token is baked at all), and a buffer switch (which changes the baked
	-- source path and possibly the md<->html mode) — a stale non-empty token
	-- on a network bind would otherwise 401 every request, and a stale path
	-- would show the wrong filename on reload.
	local want_token = 'data-live-token="' .. (host_is_loopback() and (M._token or "") or "") .. '"'
	local want_path = 'data-source-path="' .. (source_path or "") .. '"'
	local want_mode = 'data-preview-mode="' .. (mode == "html" and "html" or "md") .. '"'
	local ok, existing = pcall(util.read_text, dst)
	if not ok
		or not existing:find(want_token, 1, true)
		or not existing:find(want_path, 1, true)
		or not existing:find(want_mode, 1, true)
	then
		return write_index(dir, source_path, mode)
	end
	return dst
end

---------------------------------------------------------------------------
-- Content writing (unified: markdown or mermaid)
---------------------------------------------------------------------------

local function extract_mermaid_under_cursor_strict(bufnr)
	local ok, text = pcall(ts.extract_under_cursor, bufnr)
	if ok and text and #text > 0 then
		return text
	end
	return nil
end

local function extract_mermaid_under_cursor(bufnr)
	local text = extract_mermaid_under_cursor_strict(bufnr)
	if text and #text > 0 then
		return text
	end
	local fallback = ts.fallback_scan(bufnr)
	if not fallback or #fallback == 0 then
		error("No ```mermaid fenced code block found under (or above) the cursor")
	end
	return fallback
end

---------------------------------------------------------------------------
-- mermaid-rs-renderer (mmdr) integration
---------------------------------------------------------------------------

---Check if mmdr CLI is available; caches result after first probe.
---@return boolean
local function is_mmdr_available()
	if M._mmdr_available ~= nil then
		return M._mmdr_available
	end
	M._mmdr_available = vim.fn.executable("mmdr") == 1
	if not M._mmdr_available then
		vim.notify(
			"Markdown Preview: mermaid_renderer='rust' but `mmdr` not found in PATH.\n"
				.. "Install: cargo install mermaid-rs-renderer\n"
				.. "Falling back to browser-side mermaid.js.",
			vim.log.levels.WARN
		)
	end
	return M._mmdr_available
end

---Render a single mermaid diagram source via mmdr CLI.
---@param source string Raw mermaid diagram text
---@return string|nil svg SVG string on success
---@return string|nil err Error message on failure
local function render_mermaid_via_mmdr(source)
	local result = vim.fn.system({ "mmdr", "-e", "svg" }, source)
	if vim.v.shell_error ~= 0 then
		return nil, result
	end
	return result, nil
end

-- Expand button SVG used in pre-rendered blocks (matches browser-side fence renderer)
local EXPAND_BTN_SVG = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none">'
	.. '<path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
	.. "</svg>"

---Pre-render ```mermaid fences via mmdr, replacing them with HTML blocks.
---Failed renders leave the original fence untouched for browser-side fallback.
---@param text string Full markdown text
---@return string text Markdown with pre-rendered mermaid blocks
local function prerender_mermaid_blocks(text)
	local rust_idx = 0
	local out = {}
	local pos = 1

	while true do
		-- Find opening ```mermaid fence
		local fence_start, fence_end = text:find("\n```mermaid%s*\n", pos)
		if not fence_start then
			-- Also check at the very start of the document
			if pos == 1 then
				fence_start, fence_end = text:find("^```mermaid%s*\n")
			end
			if not fence_start then
				break
			end
		end

		-- Find closing ```
		local close_start, close_end = text:find("\n```%s*\n", fence_end)
		if not close_start then
			-- Try closing at end of file
			close_start, close_end = text:find("\n```%s*$", fence_end)
			if not close_start then
				break
			end
		end

		-- Extract mermaid source between fences
		local source = text:sub(fence_end + 1, close_start - 1)
		if source and #source > 0 then
			local svg, _err = render_mermaid_via_mmdr(source)
			if svg then
				rust_idx = rust_idx + 1
				local block_id = "mmd-rust-" .. rust_idx
				local encoded = vim.uri_encode(source, "rfc2396")

				local html_block = '<div class="mermaid-block mermaid-rendered" id="'
					.. block_id
					.. '" data-mermaid-source="'
					.. encoded
					.. '" data-graph="mermaid" data-prerendered="true">'
					.. '<button class="mermaid-expand-btn" title="Expand diagram" data-expand="'
					.. block_id
					.. '">'
					.. EXPAND_BTN_SVG
					.. "</button>"
					.. '<div class="mermaid-svg-wrap">'
					.. svg
					.. "</div>"
					.. "</div>"

				-- Append text before fence + the HTML block
				out[#out + 1] = text:sub(pos, fence_start - 1)
				out[#out + 1] = "\n" .. html_block .. "\n"
				pos = close_end + 1
			else
				-- mmdr failed for this block — leave fence untouched for JS fallback
				out[#out + 1] = text:sub(pos, close_end)
				pos = close_end + 1
			end
		else
			out[#out + 1] = text:sub(pos, close_end)
			pos = close_end + 1
		end
	end

	-- Append remaining text
	out[#out + 1] = text:sub(pos)
	return table.concat(out)
end

---------------------------------------------------------------------------
-- Content writing (unified: markdown, mermaid or html)
---------------------------------------------------------------------------

---Preview mode for a buffer: "html" for ft=html buffers, "md" otherwise.
local function preview_mode_for(bufnr)
	return vim.bo[bufnr].filetype == "html" and "html" or "md"
end

---Workspace content filename for a preview mode.
local function content_name_for(mode)
	return mode == "html" and M.config.html_content_name or M.config.content_name
end

---Get the content to write based on filetype.
---HTML buffers: entire buffer, raw (rendered in an iframe by the browser).
---Markdown buffers: entire buffer.
---Mermaid files (.mmd, .mermaid): entire buffer wrapped in mermaid fence.
---Others: mermaid block under cursor wrapped in fence.
---@param bufnr integer
---@return string text
---@return string mode "md"|"html"
local function get_content(bufnr)
	local text
	local mode = "md"
	local ft = vim.bo[bufnr].filetype
	if ft == "html" then
		-- HTML buffers: raw buffer text, no wrapping, no prerendering
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = table.concat(lines, "\n")
		mode = "html"
	elseif ft == "markdown" then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = table.concat(lines, "\n")
	elseif vim.api.nvim_buf_get_name(bufnr):match("%.mmd$")
        or vim.api.nvim_buf_get_name(bufnr):match("%.mermaid$") then
		-- .mmd / .mermaid files: treat entire buffer as mermaid
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = "```mermaid\n" .. table.concat(lines, "\n") .. "\n```\n"
	else
		-- Other filetypes: extract mermaid block under cursor, wrap in code fence
		local mermaid_text = extract_mermaid_under_cursor(bufnr)
		text = "```mermaid\n" .. mermaid_text .. "\n```\n"
	end

	-- Pre-render mermaid blocks via mmdr if configured. Skipped when raw HTML
	-- is disabled: pre-rendering injects <svg> markup into content.md, which
	-- markdown-it would escape to literal text under html:false. The browser-
	-- side renderer handles the fences instead (it doesn't need raw HTML).
	-- Also gated on md mode: an HTML buffer containing ```mermaid text must
	-- not be mangled.
	if mode == "md"
		and M.config.mermaid_renderer == "rust"
		and M.config.allow_raw_html ~= false
		and is_mmdr_available()
	then
		text = prerender_mermaid_blocks(text)
	end

	return text, mode
end

---Same as get_content but never errors (returns nil on failure).
---@param bufnr integer
---@return string|nil text
---@return string|nil mode "md"|"html"
local function get_content_safe(bufnr)
	local ok, text, mode = pcall(get_content, bufnr)
	if ok and text and #text > 0 then
		return text, mode
	end
	return nil
end

local function write_content(dir, text, bufnr, mode)
	local path = vim.fs.joinpath(dir, content_name_for(mode))
	util.write_text(path, text)
	-- Sidecar recording the source file's directory. The server's asset
	-- route resolves relative image paths against it; using a file (rather
	-- than server state) lets takeover secondaries retarget it by simply
	-- writing into the shared workspace.
	if bufnr then
		local name = vim.api.nvim_buf_get_name(bufnr)
		local src_dir = name ~= "" and vim.fs.dirname(name) or nil
		if src_dir and src_dir ~= "" then
			pcall(util.write_text, vim.fs.joinpath(dir, "asset_root"), src_dir)
		end
	end
	return path
end

---------------------------------------------------------------------------
-- Refresh logic
---------------------------------------------------------------------------

local function maybe_refresh(bufnr, silent)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local text, mode = get_content_safe(bufnr)
	if not text then
		return false
	end

	if M._last_text_by_buf[bufnr] == text then
		return false
	end

	local dir = M._workspace_dir or ensure_workspace(bufnr)
	write_content(dir, text, bufnr, mode)
	M._last_text_by_buf[bufnr] = text

	-- Notify live-server of the content change for immediate SSE push.
	-- The content filename doubles as the mode signal: the browser derives
	-- md/html mode from the reload event's changed-path basename.
	-- In secondary takeover mode, M._server_instance is nil — fs_watch handles reload
	if M._server_instance then
		pcall(ls_server.reload, M._server_instance, content_name_for(mode))
	end

	if not silent and M.config.notify_on_refresh then
		vim.notify("Markdown preview updated", vim.log.levels.INFO)
	end
	return true
end

local function debounced_refresh(bufnr)
	M._debounce_seq = M._debounce_seq + 1
	local this_call = M._debounce_seq
	vim.defer_fn(function()
		if this_call ~= M._debounce_seq then
			return
		end
		pcall(maybe_refresh, bufnr, true)
	end, M.config.debounce_ms)
end

---------------------------------------------------------------------------
-- Scroll sync (line-based)
---------------------------------------------------------------------------

--- Send cursor line to browser for scroll sync.
local function send_scroll_sync(bufnr)
	if not M.config.scroll_sync then return end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-based
	if cursor_line == M._last_scroll_line then return end
	M._last_scroll_line = cursor_line
	local total = vim.api.nvim_buf_line_count(bufnr)
	local payload = vim.json.encode({ line = cursor_line - 1, total = total })
	if M._server_instance then
		pcall(ls_server.send_event, M._server_instance, "scroll", payload)
	elseif M._takeover_port then
		require("markdown_preview.remote").send_event(M._takeover_port, "scroll", payload, M._token)
	end
end

--- Resolve the source file's path relative to the current working directory,
--- falling back to the basename (and finally the absolute path) so the header
--- always has something meaningful. Returns "" for unnamed buffers.
local function source_display_path(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if not name or name == "" then return "" end
	local cwd = vim.fn.getcwd()
	-- Make both absolute before comparing so a relative cwd can't slip through.
	local abs_name = vim.fn.fnamemodify(name, ":p")
	local abs_cwd = vim.fn.fnamemodify(cwd, ":p")
	if abs_name:sub(1, #abs_cwd) == abs_cwd then
		local rel = abs_name:sub(#abs_cwd + 1)
		if rel ~= "" then return rel end
	end
	-- Outside the cwd: show the basename rather than a long absolute path.
	local base = vim.fn.fnamemodify(name, ":t")
	return base ~= "" and base or name
end

--- Push the source file's display path (and preview mode) to the browser
--- header (live preview). Sent on start and on retarget so buffer switches
--- update the header live; the mode lets takeover secondaries flip the
--- browser between markdown and HTML rendering.
local function send_source(bufnr)
	local path = source_display_path(bufnr)
	if path == "" then return end
	local payload = vim.json.encode({ path = path, mode = preview_mode_for(bufnr) })
	if M._server_instance then
		pcall(ls_server.send_event, M._server_instance, "source", payload)
	elseif M._takeover_port then
		require("markdown_preview.remote").send_event(M._takeover_port, "source", payload, M._token)
	end
end

---------------------------------------------------------------------------
-- Autocmds
---------------------------------------------------------------------------

local function set_autocmds_for_buffer(bufnr)
	if M._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
	end
	M._augroup = vim.api.nvim_create_augroup("MarkdownPreviewAuto", { clear = true })

	if M.config.auto_refresh then
		for _, ev in ipairs(M.config.auto_refresh_events) do
			vim.api.nvim_create_autocmd(ev, {
				group = M._augroup,
				buffer = bufnr,
				callback = function()
					debounced_refresh(bufnr)
				end,
				desc = "Markdown Preview auto-refresh (debounced)",
			})
		end
	end

	for _, ev in ipairs({ "CursorMoved", "CursorMovedI" }) do
		vim.api.nvim_create_autocmd(ev, {
			group = M._augroup,
			buffer = bufnr,
			callback = function() send_scroll_sync(bufnr) end,
			desc = "Markdown Preview scroll sync",
		})
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- When bound to 0.0.0.0 detect the outbound LAN IP via a UDP connect trick
-- (no packets are sent; it just lets the kernel pick the right interface).
local function lan_ip()
	local udp = vim.loop.new_udp()
	if not udp then return "127.0.0.1" end
	local ok = pcall(function() udp:connect("8.8.8.8", 80) end)
	local addr = ok and udp:getsockname()
	pcall(function() udp:close() end)
	return (addr and addr.ip) or "127.0.0.1"
end

-- Build the URL the browser opens to. Embeds the auth token when one exists
-- so the first request includes it (the page then stashes it in
-- sessionStorage for refreshes).
local function browser_url(port)
	local display_host = (M.config.host == "0.0.0.0") and lan_ip() or M.config.host
	local base = ("http://%s:%d/"):format(display_host, port)
	if M._token and M._token ~= "" then
		return base .. "?t=" .. M._token
	end
	return base
end

function M.start()
	local bufnr = vim.api.nvim_get_current_buf()
	M._active_bufnr = bufnr

	-- Takeover coordination (lock probe + cross-instance events) talks to
	-- 127.0.0.1, which a specific-interface bind does not answer on. Only
	-- loopback and the wildcard are supported there; multi mode has no such
	-- coupling and accepts any bind address.
	if M.config.instance_mode == "takeover" and not host_is_loopback() and M.config.host ~= "0.0.0.0" then
		vim.notify(
			'Markdown Preview: takeover mode supports host = "127.0.0.1" or "0.0.0.0" only.\n'
				.. 'Use "0.0.0.0" for LAN access, or instance_mode = "multi" to bind a specific interface.',
			vim.log.levels.ERROR
		)
		return
	end

	local ok_content, text, mode = pcall(get_content, bufnr)
	if not ok_content then
		vim.notify("Markdown Preview: " .. tostring(text), vim.log.levels.ERROR)
		return
	end

	-- Resolve workspace: shared (takeover) or per-buffer (multi)
	local dir
	if M.config.instance_mode == "takeover" then
		dir = util.shared_workspace()
	else
		dir = ensure_workspace(bufnr)
	end
	util.mkdirp(dir)
	M._workspace_dir = dir

	-- Decide role + token BEFORE writing index.html. The index bakes the
	-- token in via the __LIVE_TOKEN__ placeholder, so we need it ready.
	if M.config.instance_mode == "takeover" and not M._server_instance then
		local lock = require("markdown_preview.lock")
		local lock_data = lock.read()
		if lock_data and lock.is_server_alive(lock_data.port) then
			-- Secondary: server is already running in another Neovim
			-- instance. Adopt its token so our scroll-sync RPC works.
			M._is_primary = false
			M._takeover_port = lock_data.port
			M._token = lock_data.token
			write_content(dir, text, bufnr, mode)
			M._last_text_by_buf[bufnr] = text
			set_autocmds_for_buffer(bufnr)
			send_source(bufnr)
			if type(M.config.hooks.on_start) == "function" then
				M.config.hooks.on_start(browser_url(lock_data.port))
			end
			return
		end
		-- Stale lock or no lock, we become primary
		lock.remove()
	end

	-- Primary path (takeover) or single-instance (multi). Generate a token
	-- once per server lifetime and reuse it across retargets.
	if not M._token or M._token == "" then
		M._token = ls_util.random_token(16)
	end

	write_index_if_needed(dir, source_display_path(bufnr), mode)
	write_content(dir, text, bufnr, mode)
	M._last_text_by_buf[bufnr] = text

	set_autocmds_for_buffer(bufnr)

	-- Patterns matching workspace-served files that require ?t=<token>.
	-- vim.pesc escapes every Lua-pattern magic char, so custom content_name /
	-- index_name values containing '-', '+', '.', etc. still gate correctly.
	local content_path_pattern = "^/" .. vim.pesc(M.config.content_name) .. "$"
	-- Gated even in pure-markdown sessions: the server and workspace are
	-- shared, so a takeover secondary may write content.html later while the
	-- pattern list is only built once, here, at server start.
	local html_path_pattern = "^/" .. vim.pesc(M.config.html_content_name) .. "$"

	-- The asset_root sidecar is gated too: it holds the source file's
	-- directory path, which is nobody's business but ours.
	local protected = { content_path_pattern, html_path_pattern, "^/asset_root$" }
	if not host_is_loopback() then
		-- On a network bind the index page must be gated too: it is the
		-- browser's bootstrap document, and serving it openly would hand the
		-- preview to any peer that can reach the port. The tokenized ?t= URL
		-- (printed by hooks.on_start / opened by the browser) unlocks it.
		table.insert(protected, "^/$")
		table.insert(protected, "^/" .. vim.pesc(M.config.index_name) .. "$")
	end

	-- Relative image support needs the asset route in live-server. The two
	-- plugins are versioned independently, so warn (once) if the installed
	-- live-server predates it — images will 404 until it's updated.
	if not (ls_server.features and ls_server.features.asset_route) and not M._warned_no_asset_route then
		M._warned_no_asset_route = true
		vim.notify(
			"Markdown Preview: relative images need a newer live-server.nvim (with the asset route).\n"
				.. "Update live-server.nvim, or relative images will not load.",
			vim.log.levels.WARN
		)
	end

	-- Start live-server if not already running
	if not M._server_instance then
		local port = effective_port()
		local index_path = vim.fs.joinpath(dir, M.config.index_name)
		local ok, inst = pcall(ls_server.start, {
			port = port,
			host = M.config.host,
			root = dir,
			default_index = index_path,
			headers = { ["Cache-Control"] = "no-cache" },
			-- No cors: the preview page is same-origin and remote.lua talks raw
			-- TCP. A wildcard ACAO would let any website in the user's browser
			-- read the token out of the (unauthenticated) index page.
			live = {
				enabled = true,
				inject_script = false,
				debounce = 100,
			},
			features = { dirlist = { enabled = false } },
			token = M._token,
			protected_paths = protected,
			-- Resolve relative image paths against the source file's dir
			-- (issue #17). Read per request so takeover secondaries and
			-- buffer switches retarget it via the sidecar.
			asset_root = function()
				local ws = M._workspace_dir
				if not ws then return nil end
				local ok_read, data = pcall(util.read_text, vim.fs.joinpath(ws, "asset_root"))
				if not ok_read or not data or data == "" then return nil end
				return (data:gsub("%s+$", ""))
			end,
		})
		if not ok then
			vim.notify(
				("Markdown Preview: failed to start server (port %s) — %s"):format(tostring(port), tostring(inst)),
				vim.log.levels.ERROR
			)
			return
		end
		M._server_instance = inst
		M._is_primary = true
		M._takeover_port = nil

		-- Write lock file in takeover mode
		if M.config.instance_mode == "takeover" then
			require("markdown_preview.lock").write(inst.port, dir, M._token)
		end

		if type(M.config.hooks.on_start) == "function" then
			M.config.hooks.on_start(browser_url(inst.port))
		end

		if M.config.open_browser then
			vim.defer_fn(function()
				util.open_in_browser(browser_url(inst.port), M.config.browser)
			end, 200)
		end

		-- The browser hasn't connected to SSE yet on a fresh start (it opens
		-- ~200ms above), so defer the source event until it likely has.
		vim.defer_fn(function() send_source(bufnr) end, 400)
	else
		-- Server already running, retarget to this buffer's workspace.
		-- Rewrite the index so its baked source path and preview mode match
		-- this buffer (a reload of the page would otherwise show a stale
		-- filename or render HTML buffers as markdown).
		write_index_if_needed(dir, source_display_path(bufnr), mode)
		local index_path = vim.fs.joinpath(dir, M.config.index_name)
		pcall(ls_server.update_target, M._server_instance, dir, index_path)
		pcall(ls_server.reload, M._server_instance, content_name_for(mode))

		if type(M.config.hooks.on_start) == "function" then
			M.config.hooks.on_start(browser_url(M._server_instance.port))
		end

		-- No browser tab connected (user closed it)? Re-open.
		if M.config.open_browser and ls_server.connected_client_count(M._server_instance) == 0 then
			vim.defer_fn(function()
				util.open_in_browser(browser_url(M._server_instance.port), M.config.browser)
			end, 200)
		end

		-- Browser is already connected on a retarget; send immediately.
		send_source(bufnr)
	end
end

function M.refresh()
	local bufnr = vim.api.nvim_get_current_buf()
	local changed = maybe_refresh(bufnr, false)
	if not changed and M.config.notify_on_refresh then
		vim.notify("Markdown Preview: no changes detected", vim.log.levels.INFO)
	end
end

function M.stop()
	if M._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
		M._augroup = nil
	end
	if M._server_instance then
		pcall(ls_server.stop, M._server_instance)
		M._server_instance = nil
	end
	if M._is_primary then
		require("markdown_preview.lock").remove()
	end
	M._workspace_dir = nil
	M._last_scroll_line = nil
	M._is_primary = nil
	M._takeover_port = nil
	M._token = nil

	if type(M.config.hooks.on_stop) == "function" then
		M.config.hooks.on_stop()
	end
end

return M
