/// tina_file_resources — a plugin that reads a folder and modifies a
/// prompt: the prompt phase lists the folder's items (names and
/// descriptions only, never bodies) and one tool fetches a body by name.
///
/// A plain local-folder reader, not a registry: no `SkillSource`
/// abstraction, no ranks, no precedence, no lazy listing, no exposure
/// flags, no catalog. Everything that machinery handled in the old
/// engine — remote sources, sources overriding each other — does not
/// apply to reading one local directory.
///
/// Nothing here is skill-specific. Skills are the first use of this, a
/// folder convention (see `SKILLS.md` in this package), not a package.
library;

export 'src/plugin.dart';
export 'src/resource_files.dart';
export 'src/resources_tool.dart';
