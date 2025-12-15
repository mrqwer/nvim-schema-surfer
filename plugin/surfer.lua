if exists("g:loaded_schema_surfer") then return end
g:loaded_schema_surfer = 1

vim.api.nvim_create_user_command("SchemaSurf", function(opts)
    require("schema-surfer").load_schema(opts.args)
end, { nargs = 1, desc = "Connect to DB: :SchemaSurf postgres://..." })
