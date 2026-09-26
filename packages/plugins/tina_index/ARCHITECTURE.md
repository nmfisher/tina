# tina_index

An AST-derived dependency graph for Dart code, plus content hashing and
keyword seeding — the machinery behind `/index` and index-aware exploration.
Pure `analyzer` + `path` in, serializable graph out; no engine dependency.

- `symbol.dart` / `symbol_table.dart` — symbol nodes + qualified-name index.
- `edge.dart` / `graph.dart` — typed edges and `CodeGraph` with
  bidirectional lookup.
- `extractor.dart` / `graph_builder.dart` / `walker.dart` — parse Dart into
  symbols, build edges, discover files.
- `hasher.dart` — FNV-1a content hashing, so unchanged files skip re-parsing.
- `store.dart` — serialize/deserialize the graph to disk.
- `traversal.dart` — expand seed symbols through the graph ("what does this
  symbol touch").
- `seeding.dart` / `fuzzy.dart` — natural-language query → seed node ids.

Consumers: `tina_engine` (index-aware tools), the app layer (exposes
indexing progress as `tina.index-progress`), the TUI `/index` browser.
