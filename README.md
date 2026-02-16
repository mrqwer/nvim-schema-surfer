# nvim-schema-surfer

Minimal DB schema explorer inside Neovim.

## Features
- ASCII ERD dashboard
- Table navigation through FK relations
- Data preview and SQL scratchpad
- Join clause yank helper

## Installation (lazy.nvim)

```lua
{
  "mrqwer/nvim-schema-surfer",
  dependencies = { "nvim-telescope/telescope.nvim" },
  build = "cargo build --manifest-path engine/Cargo.toml --release",
  opts = {
    db_uri_env = "DATABASE_URL", -- optional: read DB URI from env
    -- db_uri = "postgresql://user:pass@localhost:5432/db",
    -- db_uri = function() return require("my_client").current_db_uri() end,
    -- engine_profile = "debug", -- faster first compile
  },
  keys = {
    {
      "<leader>dbb",
      function()
        require("schema-surfer").load_schema()
      end,
      desc = "Open Database Schema",
    },
  },
}
```

## Usage

- `:SchemaSurf` uses URI from `setup({ db_uri = ... })` or `db_uri_env`.
- `:SchemaSurf postgresql://...` uses an explicit URI.

If engine binary is missing, the plugin now attempts a one-time Cargo build automatically.
