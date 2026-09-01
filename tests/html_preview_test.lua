-- tests/html_preview_test.lua
-- HTML-buffer preview: ft=html buffers write content.html (not content.md),
-- the file is token-gated, the served index bakes data-preview-mode="html",
-- refresh reloads carry the html content name, and the 'source' SSE payload
-- includes the mode. Markdown sessions also protect content.html (shared
-- server + workspace with takeover secondaries).
--
-- Run: nvim --headless -u NONE \
--   -c "set rtp+=<path-to-live-server.nvim>" \
--   -c "set rtp+=." -c "luafile tests/html_preview_test.lua" -c "qa!"
-- Locally <path-to-live-server.nvim> is ~/.local/share/nvim/lazy/live-server.nvim

local uv = vim.loop

-- ─── Setup: open an HTML buffer ─────────────────────────────────────────────
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local htmlfile = vim.fs.joinpath(tmpdir, "test.html")
do
	local fd = uv.fs_open(htmlfile, "w", 420)
	uv.fs_write(fd, "<!DOCTYPE html>\n<h1>hello html</h1>\n", 0)
	uv.fs_close(fd)
end

vim.cmd("edit " .. htmlfile)
vim.bo.filetype = "html"

-- ─── Configure: no browser, multi mode for isolation ───────────────────────
local mp = require("markdown_preview")
mp.setup({
	open_browser = false,
	instance_mode = "multi",
})

-- ─── Capture reload name + source payload via monkeypatch ──────────────────
local ls_server = require("live_server.server")
local orig_reload, orig_send_event = ls_server.reload, ls_server.send_event
local cap_reload, cap_source
ls_server.reload = function(inst, path) cap_reload = path end
ls_server.send_event = function(inst, event, data)
	if event == "source" then cap_source = data end
	return orig_send_event(inst, event, data)
end

mp.start()

local passed, failed = 0, 0
local function ok(cond, msg)
	if cond then
		passed = passed + 1
		print("  PASS: " .. msg)
	else
		failed = failed + 1
		print("  FAIL: " .. msg)
	end
end

local function http_get(url)
	local out = vim.fn.system({ "curl", "-s", "-o", "-", "-w", "\nHTTPSTATUS:%{http_code}", url })
	local body, status = out:match("^(.*)\nHTTPSTATUS:(%d+)%s*$")
	return { status = tonumber(status), body = body or "" }
end

local function read_ws(name)
	local fd = uv.fs_open(vim.fs.joinpath(mp._workspace_dir, name), "r", 420)
	if not fd then return nil end
	local stat = uv.fs_fstat(fd)
	local data = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	return data
end

-- ─── Section 1: dispatch + gating + index baking ───────────────────────────
ok(mp._server_instance ~= nil, "server instance created")
local port = mp._server_instance.port

local html_content = read_ws("content.html")
ok(html_content ~= nil and html_content:find("hello html", 1, true) ~= nil,
	"content.html written with raw buffer text")
ok(read_ws("content.md") == nil, "content.md NOT written for ft=html buffer")

local r = http_get(("http://127.0.0.1:%d/content.html"):format(port))
ok(r.status == 401, "/content.html without token is 401")

r = http_get(("http://127.0.0.1:%d/content.html?t=%s"):format(port, mp._token))
ok(r.status == 200, "/content.html with token is 200")
ok(r.body:find("hello html", 1, true) ~= nil, "/content.html body matches buffer")

local index = read_ws("index.html")
ok(index ~= nil and index:find('data-preview-mode="html"', 1, true) ~= nil,
	"index bakes data-preview-mode=html")
ok(index ~= nil and index:find('data-html-sandbox="false"', 1, true) ~= nil,
	"index bakes data-html-sandbox=false (default)")
ok(index ~= nil and index:find('data-html-name="content.html"', 1, true) ~= nil,
	"index bakes data-html-name=content.html")

-- ─── Section 2: refresh reload name + source payload mode ──────────────────
vim.api.nvim_buf_set_lines(0, 1, 2, false, { "<p>edited</p>" })
mp.refresh()
ok(cap_reload == "content.html", "refresh reloads carry content.html (browser mode signal)")

ok(vim.wait(600, function() return cap_source ~= nil end, 50), "source event fired (deferred)")
ok(cap_source ~= nil and vim.json.decode(cap_source).mode == "html",
	"source event payload includes mode=html")

-- ─── Section 3: markdown control + shared html gating ──────────────────────
ls_server.reload, ls_server.send_event = orig_reload, orig_send_event
mp.stop()

local mdfile = vim.fs.joinpath(tmpdir, "test.md")
do
	local fd = uv.fs_open(mdfile, "w", 420)
	uv.fs_write(fd, "# md title\n", 0)
	uv.fs_close(fd)
end
vim.cmd("edit " .. mdfile)
vim.bo.filetype = "markdown"
mp.start()

ok(read_ws("content.md") ~= nil, "markdown buffer writes content.md")
local index2 = read_ws("index.html")
ok(index2 ~= nil and index2:find('data-preview-mode="md"', 1, true) ~= nil,
	"index bakes data-preview-mode=md for markdown")

r = http_get(("http://127.0.0.1:%d/content.html"):format(mp._server_instance.port))
ok(r.status == 401,
	"/content.html still 401 in a pure-markdown session (pattern shared at server start)")

-- ─── Stop and verify cleanup ────────────────────────────────────────────────
mp.stop()
ok(mp._server_instance == nil, "_server_instance cleared after stop")

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", passed, failed))
print(string.format("========================================"))

if failed > 0 then vim.cmd("cq 1") end
