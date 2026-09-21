import 'package:classifier/classification.dart';

import 'project_classifiers.dart';

// Extension rules live in this implementation, not the source or tree merger.
// Ambiguous suffixes such as .h and .m are deliberately left unmapped.
const languageExtensions = {
  '.ada': 'ada',
  '.adb': 'ada',
  '.ads': 'ada',
  '.asm': 'assembly',
  '.s': 'assembly',
  '.sh': 'bash',
  '.bash': 'bash',
  '.c': 'c',
  '.C': 'cpp',
  '.cc': 'cpp',
  '.cpp': 'cpp',
  '.cxx': 'cpp',
  '.hpp': 'cpp',
  '.hh': 'cpp',
  '.hxx': 'cpp',
  '.cs': 'csharp',
  '.clj': 'clojure',
  '.cljs': 'clojure',
  '.cljc': 'clojure',
  '.cmake': 'cmake',
  '.cob': 'cobol',
  '.cbl': 'cobol',
  '.coffee': 'coffeescript',
  '.css': 'css',
  '.cu': 'cuda',
  '.cuh': 'cuda',
  '.dart': 'dart',
  '.ex': 'elixir',
  '.exs': 'elixir',
  '.elm': 'elm',
  '.erl': 'erlang',
  '.hrl': 'erlang',
  '.f': 'fortran',
  '.f90': 'fortran',
  '.f95': 'fortran',
  '.fs': 'fsharp',
  '.fsx': 'fsharp',
  '.glsl': 'glsl',
  '.go': 'go',
  '.groovy': 'groovy',
  '.hs': 'haskell',
  '.lhs': 'haskell',
  '.hcl': 'hcl',
  '.tf': 'hcl',
  '.hlsl': 'hlsl',
  '.html': 'html',
  '.htm': 'html',
  '.java': 'java',
  '.js': 'javascript',
  '.jsx': 'javascript',
  '.mjs': 'javascript',
  '.cjs': 'javascript',
  '.jl': 'julia',
  '.kt': 'kotlin',
  '.kts': 'kotlin',
  '.lisp': 'lisp',
  '.lsp': 'lisp',
  '.lua': 'lua',
  '.mk': 'make',
  '.md': 'markdown',
  '.markdown': 'markdown',
  '.mdown': 'markdown',
  '.nim': 'nim',
  '.nix': 'nix',
  '.mm': 'objective-c',
  '.ml': 'ocaml',
  '.mli': 'ocaml',
  '.pas': 'pascal',
  '.pm': 'perl',
  '.php': 'php',
  '.ps1': 'powershell',
  '.psm1': 'powershell',
  '.pro': 'prolog',
  '.py': 'python',
  '.pyi': 'python',
  '.pyw': 'python',
  '.r': 'r',
  '.rkt': 'racket',
  '.rb': 'ruby',
  '.rs': 'rust',
  '.scala': 'scala',
  '.scm': 'scheme',
  '.ss': 'scheme',
  '.sol': 'solidity',
  '.sql': 'sql',
  '.swift': 'swift',
  '.tcl': 'tcl',
  '.ts': 'typescript',
  '.tsx': 'typescript',
  '.mts': 'typescript',
  '.cts': 'typescript',
  '.v': 'verilog',
  '.sv': 'verilog',
  '.svh': 'verilog',
  '.vhd': 'vhdl',
  '.vhdl': 'vhdl',
  '.vb': 'visual-basic',
  '.vue': 'vue',
  '.svelte': 'svelte',
  '.wgsl': 'wgsl',
  '.zig': 'zig',
};

/// Only filename inputs are accepted. Content, directories and file sizes play
/// no part; callers may replace the table without changing sources or storage.
LocalClassifier<TextEvidence, ProjectLabels> extensionClassifier({
  Map<String, String> extensions = languageExtensions,
}) {
  final rules = Map<String, String>.unmodifiable(extensions);
  for (final entry in rules.entries) {
    if (!RegExp(r'^\.[a-zA-Z0-9_-]+$').hasMatch(entry.key)) {
      throw ArgumentError('Invalid extension: ${entry.key}');
    }
    ProjectLabel(entry.value, const ['rule']); // Validate the output label.
  }
  return LocalClassifier(
    id: 'language.extensions',
    agentType: 'extension_classifier',
    instructions: 'Map the final filename extension to a language.',
    input: textEvidenceContract,
    output: projectLabelsContract,
    spec: {'extensions': rules, 'case': 'exact_then_lowercase'},
    classify: (input) {
      final labels = <String, Set<String>>{};
      for (final unit in input.units) {
        if (unit.value.meaning != 'repository-relative filename') {
          throw ArgumentError(
            'Extension classification requires filename inputs',
          );
        }
        final name = unit.value.text.split('/').last;
        final dot = name.lastIndexOf('.');
        if (dot <= 0 || dot == name.length - 1) continue;
        final extension = name.substring(dot);
        final language = rules[extension] ?? rules[extension.toLowerCase()];
        if (language != null) (labels[language] ??= {}).add(unit.id);
      }
      final names = labels.keys.toList()..sort();
      if (names.isEmpty) {
        return ClassificationResult(
          outcome: ClassificationOutcome.unknown,
          explanation: 'No recognized language extensions.',
        );
      }
      return ClassificationResult(
        outcome: ClassificationOutcome.classified,
        value: ProjectLabels([
          for (final name in names)
            ProjectLabel(name, labels[name]!.toList()..sort()),
        ]),
        evidence: labels.values.expand((ids) => ids).toSet().toList()..sort(),
        explanation: 'Languages identified by filename extensions.',
      );
    },
  );
}
