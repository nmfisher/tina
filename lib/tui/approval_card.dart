import 'dart:convert';

import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

/// Presentation data for an approval. Plugins can supply Renderer<ApprovalCard>.
/// Choices and their responses remain owned by the permission prompt.
class ApprovalCard {
  final PermissionPrompt prompt;
  final List<PreviewEntry> preview;
  final String? mode;
  final String? sandboxWarning;
  final bool details;
  final PermissionRule? rule;

  const ApprovalCard({
    required this.prompt,
    this.preview = const [],
    this.mode,
    this.sandboxWarning,
    this.details = false,
    this.rule,
  });

  String get title => switch (prompt.toolName) {
    'bash' || 'exec' => 'Run command',
    'edit' => 'Edit file',
    'write' => 'Write file',
    'read' => 'Read file',
    _ => prompt.toolName,
  };
}

String approvalChoiceLabel(ApprovalChoice choice) {
  final action = choice.decision == PermissionDecision.allow ? 'allow' : 'deny';
  if (!choice.remember) {
    return choice.label; // includes the explicit outside-sandbox wording
  }
  return switch (choice.scope) {
    GrantScope.conversation => '$action matching calls for this conversation',
    GrantScope.sessionDirectories => 'allow these directories for this session',
    GrantScope.sessionOutside =>
      'allow this exact invocation outside for this session',
    GrantScope.call => choice.label,
  };
}

/// Tool-specific content inside the shared inline approval frame. Pure: file
/// previews are prepared once by the host, never during painting or scrolling.
class ApprovalRenderer extends Renderer<ApprovalCard> {
  const ApprovalRenderer();

  @override
  List<RenderLine> render(ApprovalCard card, RenderContext context) {
    final prompt = card.prompt;
    final input = prompt.input;
    final execution = prompt.execution;
    final theme = context.theme.chat;
    final lines = <RenderLine>[];
    void add(String text, [String? style]) {
      for (final line in approvalWrap(text, context.width)) {
        lines.add(RenderLine(runs: [RenderRun(line, style)]));
      }
    }

    if (prompt.outsideSandbox) {
      add(
        'Outside sandbox: can write anywhere your account can.',
        theme.yellow,
      );
    } else if (card.sandboxWarning != null) {
      add(card.sandboxWarning!, theme.yellow);
    }
    if (prompt.toolName == 'bash' || prompt.toolName == 'exec') {
      add(
        'Directory: ${execution?.workingDirectory ?? input['cwd'] ?? '(project directory)'}',
        theme.dim,
      );
      if (execution != null && execution.environmentOverrides.isNotEmpty) {
        add(
          'Environment: ${execution.environmentOverrides.length} overrides (Tab details)',
          theme.yellow,
        );
      }
      add('');
      if (execution?.shell == true &&
          execution!.arguments.length == 2 &&
          execution.arguments.first == '-c') {
        add(execution.arguments.last);
      } else if (prompt.toolName == 'bash') {
        add('${input['command'] ?? '(no command)'}');
      } else {
        add('Executable: ${execution?.executable ?? input['executable']}');
        final args =
            execution?.arguments ?? (input['args'] as List? ?? const []);
        for (var i = 0; i < args.length; i++) {
          add('Argument ${i + 1}: ${jsonEncode(args[i])}');
        }
      }
      add('');
    } else if (card.preview.isEmpty) {
      for (final entry in input.entries) {
        add(
          '${entry.key}: ${entry.value is String ? entry.value : jsonEncode(entry.value)}',
        );
      }
    }

    for (final entry in card.preview) {
      switch (entry) {
        case PreviewHeader(:final text):
          add(text);
        case PreviewAdded(:final text):
          add('+ $text', theme.green);
        case PreviewRemoved(:final text):
          add('- $text', theme.red);
        case PreviewContext(:final text):
          add('  $text', theme.dim);
        case PreviewSeparator():
          add('⋯', theme.dim);
      }
    }
    if (prompt.outsideSandbox) {
      if (prompt.retryExplanation != null)
        add(prompt.retryExplanation!, theme.yellow);
      add(
        'Retries the entire command; the first attempt may have made changes.',
        theme.yellow,
      );
      if (prompt.sandboxNetworkIsolated) {
        add('Also removes network isolation.', theme.yellow);
      }
    } else if (prompt.sandboxAccess case final access?) {
      add(
        'Additional writable directories (including contents):',
        theme.yellow,
      );
      for (final path in access.paths) {
        add('  $path', theme.yellow);
      }
      add('Reason: ${access.reason}');
      if (prompt.retryExplanation != null) add(prompt.retryExplanation!);
      if (prompt.retrySafety != null)
        add('Agent assessment: ${prompt.retrySafety}');
      add(
        'The command is approved once; remembered directories are shared by this project’s agents for this session.',
        theme.dim,
      );
    } else {
      // Serialized invocations are readable above; don't repeat their JSON.
      add(
        card.rule != null
            ? 'Remember regex: "${card.rule!.pattern}" for this conversation, until tina exits.'
            : prompt.target.invocation
            ? 'Remember: this exact invocation for this conversation, until tina exits.'
            : 'Remember: "${prompt.alwaysPattern}" for this conversation, until tina exits.',
        theme.dim,
      );
    }
    if (card.mode != null) add(card.mode!, theme.dim);
    if (card.details) {
      add('');
      if (prompt.outsideSandbox || prompt.sandboxAccess != null) {
        add(prompt.accessDescription.trimRight(), theme.yellow);
      }
      if (execution != null) {
        add('Executable: ${execution.executable}');
        add('Timeout: ${execution.timeoutSeconds}s');
        for (final entry in execution.environmentOverrides.entries) {
          add('Environment override: ${entry.key}=${entry.value}');
        }
        for (final path in execution.writablePaths) {
          add('Writable path: $path');
        }
      }
      add('Tool: ${prompt.toolName}', theme.dim);
      add('Rule: ${card.rule?.toString() ?? prompt.alwaysPattern}', theme.dim);
    }
    return lines;
  }
}

/// Preserve whitespace and count terminal cells when wrapping command text.
/// Control bytes are shown literally so arguments cannot become terminal codes.
List<String> approvalWrap(String text, int width) {
  width = width.clamp(1, 1 << 20);
  final visible = text.replaceAllMapped(
    RegExp(r'[\x00-\x09\x0b-\x1f\x7f]'),
    (m) => '\\x${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}',
  );
  final result = <String>[];
  for (final line in visible.split('\n')) {
    var buffer = StringBuffer();
    var used = 0;
    for (final rune in line.runes) {
      final cells = runeWidth(rune);
      if (used > 0 && used + cells > width) {
        result.add(buffer.toString());
        buffer = StringBuffer();
        used = 0;
      }
      buffer.writeCharCode(rune);
      used += cells;
    }
    result.add(buffer.toString());
  }
  return result;
}
