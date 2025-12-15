# 🏄‍♂️ nvim-schema-surfer

**Quick Hands-On Minimal Database IDE inside Neovim.**
Visualize schemas, explore relationships, X-ray data, and write SQL queries without context switching.

## ✨ Features
- **Dashboard UI:** ASCII-based Entity Relationship Diagrams (ERD).
- **Navigation:** Drill down into tables via Foreign Keys (`<Enter>`).
- **X-Ray:** Peek at real data (`p`) instantly.
- **SQL Yank:** Auto-generate `LEFT JOIN` clauses (`y`).
- **Scratchpad:** Write and run raw SQL with history support (`q`).
- **Code Jump:** Jump to model definitions in your code (`gd`).

## 📦 Installation (Lazy.nvim)

```lua
{
  "mrqwer/nvim-schema-surfer",
  dependencies = { "nvim-telescope/telescope.nvim" },
  cmd = "SchemaSurf",
  build = "cd engine && cargo build --release",
}
