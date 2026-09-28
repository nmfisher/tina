# SKILLS.md — the skills folder convention

This package reads a folder. What makes a folder *skills* is only a
convention: file layout and front-matter fields. It is documented here,
not implemented — the package ships a reader for the layout, and the
name of the concept lives in the convention, not in code.

## Where

The skills folder is whatever directory the plugin's config points at:

```yaml
# host config (illustrative)
plugins:
  - file_resources:
      directory: /workspace/.tina/skills
      heading: '## Skills'
```

A repository that wants skills for itself checks that folder in. Tina
reads it at the start of every turn; nothing about it is cached.

## File layout

One markdown file per skill. The file name is irrelevant to the
listing (the `name:` field is the item's name — duplicate names
resolve first-file-wins in name order); the `.md` suffix is
conventional, not required. Subdirectories are ignored.

## Front matter

The first thing in every file is front matter: a `---` line, then
`key: value` lines, then a closing `---` within the first 64 lines of
the file.

Exactly two fields are meaningful to the reader:

| field         | meaning                                   |
|---------------|-------------------------------------------|
| `name`        | the skill's name — unique in the folder   |
| `description` | the one line the prompt listing shows     |

Unknown fields are ignored, not errors. Missing `name` or
`description`, an unterminated front matter, or a file that does not
start with `---` is not a skill: the file is recorded as headerless
and the rest of the folder still loads.

After the closing `---` comes the body: instructions for how to do the
thing the skill names. The prompt never carries a body; the
`read_resource` tool returns it verbatim (one conventional leading
blank line trimmed).

## A skill file

```markdown
---
name: release-checklist
description: Steps to cut a release — branch, version, tag, verify CI
---

1. Cut a branch `release/v<version>` from `main`.
2. ... (the rest is the body, returned by `read_resource`)
```

## Sources and precedence

There are none. One folder, read in name order; when two files claim
the same `name`, the first file wins and the shadowed file is
recorded. If a project needs skills from several folders, it
instantiates the plugin once per folder — the plugin is cheap and each
folder keeps its own diagnostics.
