/// The reader: a directory in, items out. That is the whole abstraction.
///
/// One sync pass per call — the loop's plugin phases are sync, so the
/// plugin reads the folder on the prompt phase directly. Files are read
/// by name order, so the listing is the same every turn. Every failure
/// mode is recorded and surfaced, none throws:
///
/// - missing directory        → [ResourceListing.missingDirectory]
/// - unreadable file          → named in [ResourceListing.unreadable]
/// - file without valid head  → named in [ResourceListing.noHeader]
/// - duplicate name           → first (name-order) wins,
///                              both named in [ResourceListing.duplicates]
library;

import 'dart:convert' show LineSplitter;
import 'dart:collection';
import 'dart:io';

/// A resource file header, parsed from front matter. Exactly the two
/// fields the prompt needs — the convention may define more, the parser
/// does not keep them.
final class ResourceHeader {
  /// The item's name: the `name:` field of the front matter, not the
  /// file name.
  final String name;

  /// The `description:` field — the one line the listing shows.
  final String description;

  const ResourceHeader({required this.name, required this.description});

  @override
  String toString() => 'ResourceHeader($name)';
}

/// One loaded item: its header plus the full body.
final class ResourceItem {
  final ResourceHeader header;

  /// Everything after the front matter, verbatim. Leading blank lines
  /// trimmed; the caller renders it.
  final String body;

  /// The file the item came from — diagnostics name it.
  final String source;

  const ResourceItem(
      {required this.header, required this.body, required this.source});

  /// The header's name, lifted for convenience.
  String get name => header.name;

  /// The header's description, lifted for convenience.
  String get description => header.description;
}

/// What one pass over a directory produced. Both lists at once: the
/// listing wants the headers, a fetch wants the bodies, and a diagnostic
/// ("2 files skipped") wants the failures. Never throws for content
/// problems — a missing or unreadable file is a recorded result here.
final class ResourceListing {
  /// Items with a valid header and non-empty body, in name order —
  /// duplicates resolved, first file wins.
  final List<ResourceItem> items;

  /// Files that could not be read. File names, not error text: the
  /// reader's job is to say *what* failed, not to quote the OS.
  final List<String> unreadable;

  /// Files with no valid front matter. The fact is the point: the file
  /// is there, it is not a resource.
  final List<String> noHeader;

  /// Duplicate names as `name` → every file that declared it, in name
  /// order. The first file wins; the rest are shadowed, not dropped.
  final Map<String, List<String>> duplicates;

  /// True when [directory] did not exist or was not a directory. All
  /// other lists are then empty.
  final bool missingDirectory;

  /// The path that was read.
  final String directory;

  const ResourceListing({
    required this.items,
    required this.unreadable,
    required this.noHeader,
    required this.duplicates,
    required this.missingDirectory,
    required this.directory,
  });

  /// The recorded result for a path with no directory behind it.
  const ResourceListing.missing(this.directory)
      : items = const [],
        unreadable = const [],
        noHeader = const [],
        duplicates = const {},
        missingDirectory = true;

  /// True when the folder exists but holds no usable item — the prompt
  /// phase adds nothing for an empty folder.
  bool get isEmpty => items.isEmpty;
}

/// Reads a directory of headed markdown files and returns a
/// [ResourceListing]. Sync and plain: no caching, no watchers, no
/// listing/writing separation. One call, one pass, one result.
///
/// A resource file is a UTF-8 text file whose first line is `---` and
/// whose front matter closes with a second `---` before the 64th line.
/// Front matter fields are `key: value` lines; `name` and `description`
/// are required, unknown keys are ignored. See `SKILLS.md` for the
/// convention that makes a folder a skills folder.
ResourceListing readResourceDirectory(String directory) {
  final dir = Directory(directory);
  if (!dir.existsSync()) return ResourceListing.missing(directory);

  List<File> files;
  try {
    files = dir.listSync(followLinks: true).whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  } on FileSystemException {
    return ResourceListing.missing(directory);
  }

  final items = <ResourceItem>[];
  final unreadable = <String>[];
  final noHeader = <String>[];
  final byName = SplayTreeMap<String, List<String>>();
  final firstFile = <String, String>{};
  for (final file in files) {
    final fileName = file.uri.pathSegments.last;
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      unreadable.add(fileName);
      continue;
    }
    final parsed = parseResourceHeader(text);
    final header = parsed?.header;
    if (header == null) {
      noHeader.add(fileName);
      continue;
    }
    final previous = firstFile[header.name];
    if (previous != null) {
      (byName[header.name] ??= [previous]).add(fileName);
      continue;
    }
    firstFile[header.name] = fileName;
    byName[header.name] = [fileName];
    items.add(
        ResourceItem(header: header, body: parsed!.body, source: fileName));
  }

  // Duplicates keep every declarer, first-file-wins already applied; a
  // shadowed item's header still counts as declared, so it is listed
  // under its name, not reported as headerless.
  final duplicates = Map<String, List<String>>.from(byName)
    ..removeWhere((name, declarers) => declarers.length < 2);
  return ResourceListing(
    items: items,
    unreadable: unreadable,
    noHeader: noHeader,
    duplicates: duplicates,
    missingDirectory: false,
    directory: directory,
  );
}

/// Pull one item out of an already-read listing: the body for [name], or
/// null when the folder has no such item. Duplicate names are resolved
/// the way the listing resolved them — first file in name order wins.
ResourceItem? resourceByName(ResourceListing listing, String name) {
  for (final item in listing.items) {
    if (item.name == name) return item;
  }
  return null;
}

/// The front matter: [ResourceHeader] plus the body after it. Internal
/// to the parse step.
final class _Parsed {
  final ResourceHeader header;
  final String body;
  const _Parsed(this.header, this.body);
}

/// Strict and small: `---` first line, fields until the closing `---`
/// (inside the first 64 lines — a file that never closes its front
/// matter has no header), `key: value` only. `name` and `description`
/// required. Anything else — no front matter, unterminated front matter,
/// missing `name` or `description`, empty `name` — is no header at all:
/// the caller records the file and moves on.
_Parsed? parseResourceHeader(String text) {
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  var close = -1;
  for (var i = 1; i < lines.length && i < _maxFrontMatterLines; i++) {
    if (lines[i].trim() == '---') {
      close = i;
      break;
    }
  }
  if (close == -1) return null;

  String? name;
  String? description;
  for (var i = 1; i < close; i++) {
    final match = _field.firstMatch(lines[i]);
    if (match == null) continue;
    if (match.group(1) == 'name') name = match.group(2)?.trim();
    if (match.group(1) == 'description') description = match.group(2)?.trim();
  }
  if (name == null || name.isEmpty) return null;
  if (description == null || description.trim().isEmpty) return null;
  return _Parsed(
      ResourceHeader(name: name, description: description),
      // Everything after the closing `---`, with one leading blank line
      // trimmed — the conventional separator, not part of the body.
      lines.length > close + 1 && lines[close + 1].trim().isEmpty
          ? lines.skip(close + 2).join('\n')
          : lines.skip(close + 1).join('\n'));
}

const int _maxFrontMatterLines = 64;
final RegExp _field = RegExp(r'^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$');
