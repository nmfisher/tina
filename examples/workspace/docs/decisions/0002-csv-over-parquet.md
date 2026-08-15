# ADR 0002: CSV export, not Parquet

Date: 2026-01-14
Status: Accepted

## Context (背景)

`reports` needs an export format. Candidates: CSV and Parquet. The data is
small (thousands of rows), consumers are humans with spreadsheets, and the
build must stay dependency-free.

## Decision (决定)

CSV, RFC 4180 quoting, one file. No columnar format.

Parquet revisit triggers — either of:

- exports exceed ~1M rows, or
- a non-human consumer appears (dashboard, 数据管道).

Rejected alternatives:

| Option | Why no |
| --- | --- |
| Parquet | native dependency; overkill at this scale |
| JSONL | already the storage format; export should differ |
| XLSX | a ZIP archive just to hold a table — no |

## Consequences

- `csv_export.dart` carries its own quoting (17 lines) instead of a package.
- Wide-character titles (日本語, emoji) round-trip fine as UTF-8; callers
  must ensure they don't write UTF-8 BOMs into Excel-destined files.
