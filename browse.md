---
layout: page
title: The /browse command
permalink: /browse/
---

# The `/browse` command

`/browse` opens a standalone directory browser right in the terminal UI. It
starts at the filesystem root and lets you navigate the tree, then echoes the
selected file's absolute path into the chat.

## Using `/browse`

Type `/browse` and press enter. A centered panel opens rooted at `/`:

| Key | Action |
|-----|--------|
| `Enter` / `→` | Descend into a directory, or select a file (closes + returns its path) |
| `←` / `Backspace` | Go to the parent directory (at root, no-op) |
| `Esc` / `Ctrl-C` | Cancel (returns nothing) |
| `↑` / `↓` | Move the selection |
| `PageUp` / `PageDown` | Move by a page |

## What you see

- **Directories first** (alphabetical, cyan, trailing `/`), then files
  (alphabetical, plain).
- **Hidden files** (leading `.`) are skipped.
- The footer shows the focused entry: `dir · <name>` or `file · <human size>`.
- Long names are truncated from the front (`…`).

## Current scope

- Navigation only — there is no type-to-filter in v1.
- The selected path is echoed to the chat; injecting it into the input or
  `@` context is future work.
- Files are not opened in an editor on Enter.
