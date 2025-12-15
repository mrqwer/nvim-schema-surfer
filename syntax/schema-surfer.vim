" Same content as you provided in previous prompt
if exists("b:current_syntax")
  finish
endif
syntax match SchemaHeader "📦 TABLE:.*"
syntax match SchemaSection "🔑 COLUMNS"
syntax match SchemaSection "🕸️  RELATIONSHIPS"
syntax match SchemaArrow "-->"
syntax match SchemaArrow "<--"
syntax match SchemaType "\<integer\>"
syntax match SchemaType "\<varchar\>"
syntax match SchemaType "\<text\>"
syntax match SchemaType "\<boolean\>"
syntax match SchemaType "\<timestamp\>"
syntax match SchemaTableRef "\[.*\]"
highlight link SchemaHeader Title
highlight link SchemaSection Special
highlight link SchemaArrow Operator
highlight link SchemaType Type
highlight link SchemaTableRef Function
let b:current_syntax = "schema-surfer"
