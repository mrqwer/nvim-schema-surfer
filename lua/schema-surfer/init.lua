local M = {}
local api = vim.api
local schema_cache = {}
local history_stack = {}
local click_zones = {}
local query_history = {}

M.config = {
  db_uri = nil,
  db_uri_env = "DATABASE_URL",
  auto_build = true,
  cargo_bin = "cargo",
  engine_profile = "release",
  engine_bin = nil,
}
M._build_attempted = false

local function is_absolute_path(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

local function get_plugin_root()
  local str = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(str, ":h:h:h")
end

local function engine_extension()
  return (vim.fn.has("win32") == 1 and ".exe") or ""
end

local function build_engine()
  local root = get_plugin_root()
  local manifest = root .. "/engine/Cargo.toml"
  local cmd = { M.config.cargo_bin, "build", "--manifest-path", manifest }
  if M.config.engine_profile ~= "debug" then table.insert(cmd, "--release") end

  vim.notify("Building schema-surfer engine...", vim.log.levels.INFO)
  local ok, output = pcall(vim.fn.system, cmd)
  if not ok or vim.v.shell_error ~= 0 then
    vim.notify("Engine build failed:\n" .. tostring(output), vim.log.levels.ERROR)
    return false
  end

  return true
end

local function resolve_engine_binary()
  local root = get_plugin_root()
  local ext = engine_extension()
  local profile = (M.config.engine_profile == "debug") and "debug" or "release"

  if type(M.config.engine_bin) == "string" and M.config.engine_bin ~= "" then
    local custom = M.config.engine_bin
    if not is_absolute_path(custom) then custom = root .. "/" .. custom end
    if vim.fn.filereadable(custom) == 1 then return custom end
  end

  local candidates = {
    root .. "/engine/target/" .. profile .. "/schema-surfer-engine" .. ext,
    root .. "/engine/target/" .. profile .. "/engine" .. ext, -- legacy fallback
  }

  for _, candidate in ipairs(candidates) do
    if vim.fn.filereadable(candidate) == 1 then return candidate end
  end

  return nil
end

local function resolve_connection_string(connection_string)
  if connection_string and connection_string ~= "" then return connection_string end
  if type(M.config.db_uri) == "function" then
    local ok, value = pcall(M.config.db_uri)
    if ok and type(value) == "string" and value ~= "" then return value end
  end
  if type(M.config.db_uri) == "string" and M.config.db_uri ~= "" then return M.config.db_uri end
  if type(M.config.db_uri_env) == "string" and M.config.db_uri_env ~= "" then
    local env_value = vim.env[M.config.db_uri_env]
    if env_value and env_value ~= "" then return env_value end
  end
  return nil
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if type(M.config.connection_string) == "string" and M.config.connection_string ~= "" and
      (not M.config.db_uri or M.config.db_uri == "") then
    M.config.db_uri = M.config.connection_string
  end
end

local function exec_engine(args)
  local bin = resolve_engine_binary()

  if not bin and M.config.auto_build and not M._build_attempted then
    M._build_attempted = true
    if build_engine() then bin = resolve_engine_binary() end
  end

  if not bin then
    vim.notify(
      "Schema-surfer binary not found. Run :Lazy build nvim-schema-surfer or set setup({ engine_bin = '...' }).",
      vim.log.levels.ERROR
    )
    return nil
  end

  local cmd = { bin }
  for _, arg in ipairs(args) do table.insert(cmd, arg) end

  local ok, output = pcall(vim.fn.system, cmd)
  if not ok then
    vim.notify("System Error: " .. tostring(output), vim.log.levels.ERROR); return nil
  end

  if vim.v.shell_error ~= 0 then
    local json_ok, err_obj = pcall(vim.json.decode, output)
    if json_ok and err_obj.error then
      vim.notify("Engine Error:\n" .. err_obj.error, vim.log.levels.ERROR)
    else
      vim.notify("Fatal Error:\n" .. output, vim.log.levels.ERROR)
    end
    return nil
  end

  local parse_ok, parsed = pcall(vim.json.decode, output)
  if not parse_ok then
    vim.notify("JSON Parse Failed:\n" .. output, vim.log.levels.ERROR); return nil
  end
  return parsed
end


local function get_cache_path(conn)
  return vim.fn.stdpath("cache") .. "/schema_surfer_" .. vim.fn.sha256(conn) .. ".json"
end

function M.load_schema(connection_string, force_refresh)
  local conn = resolve_connection_string(connection_string)
  if not conn then
    vim.notify(
      "No DB URI. Pass one to load_schema(), use :SchemaSurf <uri>, or set setup({ db_uri = '...' }).",
      vim.log.levels.WARN
    ); return
  end
  M.connection_string = conn
  local cache_file = get_cache_path(conn)

  if not force_refresh and vim.fn.filereadable(cache_file) == 1 then
    print("Loading cache...")
    local ok, parsed = pcall(vim.json.decode, table.concat(vim.fn.readfile(cache_file), "\n"))
    if ok then
      schema_cache = parsed; M.open_picker(); return
    end
  end

  print("Querying DB...")
  local parsed = exec_engine({ "schema", conn })
  if not parsed then return end

  local f = io.open(cache_file, "w"); if f then
    f:write(vim.json.encode(parsed)); f:close()
  end
  schema_cache = parsed; history_stack = {}; M.open_picker()
end

function M.open_picker()
  local keys = vim.tbl_keys(schema_cache); table.sort(keys)
  require("telescope.pickers").new({}, {
    prompt_title = "Select Table",
    finder = require("telescope.finders").new_table { results = keys },
    sorter = require("telescope.config").values.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        history_stack = {}
        if selection then M.render_dashboard(selection[1]) end
      end)
      return true
    end
  }):find()
end

local function center_text(text, width)
  local len = vim.fn.strdisplaywidth(text)
  if len >= width then return text end
  local left = math.floor((width - len) / 2)
  return string.rep(" ", left) .. text .. string.rep(" ", width - len - left)
end
local function truncate(text, max_len)
  if #text <= max_len then return text end
  return string.sub(text, 1, max_len - 3) .. "..."
end

function M.render_dashboard(table_name)
  local data = schema_cache[table_name]
  if not data then return end

  local buf_name = "ERD: " .. table_name
  local existing_buf = vim.fn.bufnr(buf_name)
  local buf = (existing_buf ~= -1) and existing_buf or api.nvim_create_buf(false, true)
  if existing_buf == -1 then
    api.nvim_buf_set_name(buf, buf_name); api.nvim_set_option_value("filetype", "schema-surfer", { buf = buf })
  end
  api.nvim_set_current_buf(buf); api.nvim_set_option_value("modifiable", true, { buf = buf })

  local lines, parents, children = {}, {}, {}
  click_zones = {}
  local win_width = api.nvim_win_get_width(0)
  local main_width = math.max(50, math.floor(win_width * 0.4))

  for _, r in ipairs(data.relations) do
    if r.relation_type == "Belongs To" then table.insert(parents, r) else table.insert(children, r) end
  end

  table.insert(lines, "  Keys: <Enter>=Jump | K=Peek | p=Data | y=Join | q=SQL | gd=Code")
  table.insert(lines, "")

  if #parents > 0 then
    table.insert(lines, center_text("▲ BELONGS TO ▲", main_width + 4))
    for _, p in ipairs(parents) do
      table.insert(lines, center_text(" [ " .. p.target_table .. " ] ", main_width + 4))
      click_zones[#lines] = { { 0, 999, p.target_table } }
    end
    table.insert(lines, center_text("│", main_width + 4)); table.insert(lines, center_text("▼", main_width + 4))
  end

  table.insert(lines, "  ╔" .. string.rep("═", main_width) .. "╗")
  table.insert(lines, "  ║" .. center_text(string.upper(table_name), main_width) .. "║")
  table.insert(lines, "  ╠" .. string.rep("═", main_width) .. "╣")
  for _, col in ipairs(data.columns) do
    local icon = (col.is_pk and "🔑") or (col.is_fk and "🔗") or "  "
    local txt = string.format("%s %-25s %s", icon, col.name, truncate(col.data_type or "", 12))
    local pad = main_width - vim.fn.strdisplaywidth(txt)
    table.insert(lines, "  ║" .. txt .. string.rep(" ", math.max(0, pad)) .. "║")
  end
  table.insert(lines, "  ╚" .. string.rep("═", main_width) .. "╝")

  if #children > 0 then
    table.insert(lines, ""); table.insert(lines, center_text("▼ HAS MANY (" .. #children .. ") ▼", main_width + 4)); table
        .insert(lines, "")
    local box_w, gap = 32, 2
    local cols = math.floor((win_width - 4) / (box_w + gap)); if cols < 1 then cols = 1 end
    local row_top, row_mid, row_bot, current_col, zones_in_row = "", "", "", 0, {}

    for i, child in ipairs(children) do
      local name = truncate(child.target_table, box_w - 4)
      local pad_l, pad_r = math.floor((box_w - 2 - #name) / 2), box_w - 2 - #name - math.floor((box_w - 2 - #name) / 2)
      row_top = row_top .. "╭" .. string.rep("─", box_w - 2) .. "╮" .. string.rep(" ", gap)
      row_mid = row_mid .. "│" .. string.rep(" ", pad_l) .. name .. string.rep(" ", pad_r) .. "│" .. string.rep(" ", gap)
      row_bot = row_bot .. "╰" .. string.rep("─", box_w - 2) .. "╯" .. string.rep(" ", gap)

      local s = 2 + (current_col * (box_w + gap))
      table.insert(zones_in_row, { s, s + box_w, child.target_table })
      current_col = current_col + 1

      if current_col >= cols or i == #children then
        table.insert(lines, "  " .. row_top); table.insert(lines, "  " .. row_mid); local mid = #lines; table.insert(
          lines, "  " .. row_bot)
        click_zones[mid - 1] = zones_in_row; click_zones[mid] = zones_in_row; click_zones[mid + 1] = zones_in_row
        row_top, row_mid, row_bot, current_col, zones_in_row = "", "", "", 0, {}
      end
    end
  end

  api.nvim_buf_set_lines(buf, 0, -1, false, lines); api.nvim_set_option_value("modifiable", false, { buf = buf })

  local opts = { buffer = buf, silent = true }
  local function get_target()
    local c = api.nvim_win_get_cursor(0); local z = click_zones[c[1]]
    if not z then return nil end
    for _, i in ipairs(z) do if c[2] >= (i[1] - 2) and c[2] <= (i[2] + 2) then return i[3] end end
  end

  vim.keymap.set("n", "<CR>",
    function()
      local t = get_target(); if t then
        table.insert(history_stack, table_name); M.render_dashboard(t)
      end
    end, opts)
  vim.keymap.set("n", "<BS>",
    function() if #history_stack > 0 then M.render_dashboard(table.remove(history_stack)) else M.open_picker() end end,
    opts)
  vim.keymap.set("n", "p", function()
    local t = get_target() or table_name; print("Fetching...")
    local rows = exec_engine({ "preview", M.connection_string, t })
    if rows and #rows > 0 then M.show_results(rows) else vim.notify("No data", vim.log.levels.INFO) end
  end, opts)
  vim.keymap.set("n", "y", function()
    local t = get_target(); local sql = ""
    if t then
      local r = nil; for _, x in ipairs(data.relations) do
        if x.target_table == t then
          r = x; break
        end
      end
      if r then
        sql = string.format("LEFT JOIN %s ON %s.%s = %s.%s", r.target_table, r.target_table, r.target_col,
          table_name, r.source_col)
      else
        sql = t
      end
    else
      sql = "SELECT * FROM " .. table_name .. " LIMIT 100;"
    end
    vim.fn.setreg("+", sql); vim.notify("📋 Copied: " .. sql)
  end, opts)
  vim.keymap.set("n", "q", M.open_scratchpad, opts)
  vim.keymap.set("n", "gd", function() require("telescope.builtin").live_grep({ default_text = table_name }) end, opts)
  vim.keymap.set("n", "K", function()
    local t = get_target(); if not t or not schema_cache[t] then return end
    local l = { " 📦 " .. string.upper(t) .. " ", string.rep("─", 40) }
    for _, c in ipairs(schema_cache[t].columns) do table.insert(l, string.format(" %-20s %s", c.name, c.data_type)) end
    local b = api.nvim_create_buf(false, true); api.nvim_buf_set_lines(b, 0, -1, false, l)
    api.nvim_open_win(b, true,
      { relative = "cursor", width = 50, height = #l + 2, row = 1, col = 1, style = "minimal", border = "rounded" })
    vim.keymap.set("n", "q", ":close<CR>", { buffer = b, silent = true }); vim.keymap.set("n", "<Esc>", ":close<CR>",
      { buffer = b, silent = true })
  end, opts)
  vim.keymap.set("n", "R", function() if M.connection_string then M.load_schema(M.connection_string, true) end end, opts)
end

function M.open_scratchpad()
  vim.cmd("vsplit")
  local b = api.nvim_create_buf(false, true)
  api.nvim_set_current_buf(b)
  api.nvim_buf_set_name(b, "Surfer Scratchpad")
  api.nvim_set_option_value("filetype", "sql", { buf = b })

  local help = {
    "-- SQL SCRATCHPAD",
    "-- Run: <leader>r  |  History: <leader>h",
    "",
    "SELECT * FROM " .. (next(schema_cache) or "table") .. " LIMIT 10;",
    ""
  }
  api.nvim_buf_set_lines(b, 0, -1, false, help)

  local opts = { buffer = b, silent = true }

  vim.keymap.set("n", "<leader>r", M.run_scratchpad_query, opts) -- Standard "Run"
  vim.keymap.set("n", "R", M.run_scratchpad_query, opts)         -- Quick "Refresh/Run"

  vim.keymap.set({ "n", "i" }, "<C-CR>", M.run_scratchpad_query, opts)

  vim.keymap.set("n", "<leader>h", M.pick_history, opts)
end

function M.run_scratchpad_query()
  if not M.connection_string then
    vim.notify("No DB Connection", vim.log.levels.ERROR); return
  end
  local query = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), " ")
  if query:match("^%s*$") then return end
  table.insert(query_history, 1, query)
  print("Executing...")
  local rows = exec_engine({ "exec", M.connection_string, query })
  if rows then M.show_results(rows) end
end

function M.pick_history()
  require("telescope.pickers").new({}, {
    prompt_title = "History",
    finder = require("telescope.finders").new_table { results = query_history },
    sorter = require("telescope.config").values.generic_sorter({}),
    attach_mappings = function(pb)
      local a = require("telescope.actions"); a.select_default:replace(function()
        a.close(pb); vim.api.nvim_put({ require("telescope.actions.state").get_selected_entry()[1] }, "l", true, true)
      end); return true
    end
  }):find()
end

function M.show_results(rows)
  if #rows == 0 then
    vim.notify("Success (No rows)", vim.log.levels.INFO); return
  end
  vim.cmd("botright 15new"); local b = api.nvim_get_current_buf()
  api.nvim_set_option_value("buftype", "nofile", { buf = b }); api.nvim_set_option_value("filetype", "schema-result",
    { buf = b })
  local h = vim.tbl_keys(rows[1]); table.sort(h)
  local l = { table.concat(h, " | "), string.rep("-", 80) }
  for _, r in ipairs(rows) do
    local v = {}; for _, k in ipairs(h) do table.insert(v, tostring(r[k] or "")) end
    table.insert(l, table.concat(v, " | "))
  end
  api.nvim_buf_set_lines(b, 0, -1, false, l)
end

M.connection_string = nil
return M
