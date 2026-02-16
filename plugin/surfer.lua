-- plugin/surfer.lua

if vim.g.loaded_schema_surfer == 1 then
  return
end
vim.g.loaded_schema_surfer = 1

vim.api.nvim_create_user_command("SchemaSurf", function(opts)
  local uri = (opts.args and opts.args ~= "") and opts.args or nil
  require("schema-surfer").load_schema(uri)
end, {
  nargs = "?",
  desc = "Connect to DB (:SchemaSurf [postgres://...])"
})
