import 'package:tina_host/tina_host.dart';
import 'plugin_catalog.dart';
import 'cli_schema.dart';

// These options select application resources or a startup operation. Feature
// options are declared by their plugins and collected from the catalog below.
const configOption = CliOption(
  'config',
  description: 'Global configuration file.',
  valueName: 'FILE',
  completion: CliCompletion.file,
);
const cwdOption = CliOption(
  'cwd',
  description: 'Workspace directory.',
  valueName: 'DIR',
  completion: CliCompletion.directory,
);
const storeOption = CliOption(
  'store',
  description: 'Session store (default: workspace store).',
  valueName: 'FILE',
  completion: CliCompletion.file,
);
const resumeOption = CliOption(
  'resume',
  description:
      'Resume an ID, or select a saved session with Up/Down, Enter and Escape.',
  value: CliValue.optional,
  valueName: 'ID',
);
const continueOption = CliOption(
  'continue',
  description:
      'Reopen the most recently updated main session in the workspace store.',
  value: CliValue.none,
  abbreviation: 'c',
);
const configureOption = CliOption(
  'configure',
  description: 'Edit global provider, model, plugin and request settings.',
  value: CliValue.none,
);
const versionOption = CliOption(
  'version',
  description: 'Print the version.',
  value: CliValue.none,
  abbreviation: 'v',
);
const helpOption = CliOption(
  'help',
  description: 'Show usage.',
  value: CliValue.none,
  abbreviation: 'h',
);
const completionOption = CliOption(
  'completion',
  description: 'Print an offline shell completion script.',
  valueName: 'SHELL',
  choices: ['bash', 'zsh', 'fish'],
);
const backendOption = CliOption(
  'backend',
  description:
      'Terminal renderer: auto uses notcurses, falling back to ANSI; inside tmux auto uses ANSI.',
  valueName: 'BACKEND',
  choices: ['auto', 'ansi', 'notcurses'],
);
const importSessionsOption = CliOption(
  'import-sessions',
  description:
      'Import a legacy session root, directory, manifest or JSONL file into the session store; print IDs for --resume. Sources stay unchanged.',
  valueName: 'PATH',
  completion: CliCompletion.file,
);
const dryRunOption = CliOption(
  'dry-run',
  description: 'Preview --import-sessions without writing.',
  value: CliValue.none,
);
const yoloOption = CliOption(
  'yolo',
  description:
      'Start with every permission/approval check disabled. Use with '
      '--no-sandbox to also lift OS filesystem and network confinement. '
      'Dangerous: nothing asks for approval; no safety judge runs.',
  value: CliValue.none,
);

CliSchema applicationCliSchema({
  PluginRegistry<SessionPluginContext>? registry,
}) {
  registry ??= firstPartyPlugins();
  return CliSchema(
    bootstrap: const [
      configOption,
      cwdOption,
      storeOption,
      resumeOption,
      continueOption,
      configureOption,
      versionOption,
      helpOption,
      completionOption,
      backendOption,
      importSessionsOption,
      dryRunOption,
      yoloOption,
    ],
    plugins: {
      for (final id in registry.ids)
        if (registry.definition(id).cli case final cli?) id: cli,
    },
  );
}
