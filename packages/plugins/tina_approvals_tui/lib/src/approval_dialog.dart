/// The approval dialog: a pending [ToolUse] plus a key source to a decision.
///
/// The [KeySource] abstraction is the point: the dialog's decision logic is
/// fully testable from scripted keys with no terminal, and a raw-mode host
/// supplies a `KeySource` over its input parser later. Rendering is pure
/// rows, with the answer selector on the last row (the console's input row).
///
/// The approval channel drives this view; the engine knows no dialog types.
library;

import 'dart:convert';

import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_approvals/tina_approvals.dart';
export 'package:tina_approvals/tina_approvals.dart' show ApprovalDecision;

/// One key press, already decoded. A raw-mode host maps its parsed input
/// events to these; tests feed a list literal.
enum ApprovalKey {
  up,
  down,
  pageUp,
  pageDown,
  scrollUp,
  scrollDown,
  confirm,
  cancel,
  details,
  allow,
  deny,
  always,
  workspace,
  global,
  editCommandPattern,
  toggleReadDirectory,
  toggleWriteDirectory,
  toggleDirectory,
  directoryScope
}

/// Where keys come from. The dialog [ApprovalDialog.awaitDecision]s until a
/// key resolves or cancels it.
abstract interface class KeySource {
  /// Resolves with the next key, or null if the source closed (host
  /// shutdown, stream end) — treated as a denial, never a silent allow.
  Future<ApprovalKey?> next();
}

/// A scripted [KeySource] for tests and scripted demos.
class ScriptedKeySource implements KeySource {
  final List<ApprovalKey?> _keys;
  int _i = 0;

  ScriptedKeySource(List<ApprovalKey?> keys) : _keys = List.of(keys);

  @override
  Future<ApprovalKey?> next() async => _i < _keys.length ? _keys[_i++] : null;
}

/// What the user decided.

/// The outcome of a dialog run. A cancelled dialog ([ApprovalDecision.deny]
/// via close/cancel) denies the call; the reason says which.
class ApprovalOutcome {
  final ApprovalDecision decision;

  /// `'cancelled'` when no key confirmed the choice (source closed, escape).
  final String? reason;
  final String? commandPattern;
  final bool editCommandPattern;
  final List<DirectoryAccessGrant> directoryGrants;

  const ApprovalOutcome(this.decision,
      {this.reason,
      this.commandPattern,
      this.editCommandPattern = false,
      this.directoryGrants = const []});

  bool get isCancellation => reason == 'cancelled';
}

/// The ask context a permission dialog renders: what operation on which
/// resolved path, and why the sandbox is asking. The adapter
/// channel builds it from the channel-independent approval request.
class ApprovalAskContext {
  final String op;
  final String path;
  final String reason;
  final bool confirmation;
  final Map<String, Object?> details;
  const ApprovalAskContext(this.op, this.path, this.reason,
      {this.confirmation = false, this.details = const {}});

  String get title => switch (op) {
        'write' => 'Write file',
        'read' => 'Read file',
        _ => op,
      };
}

/// Selection state and rendering for one pending tool call.
///
/// The dialog does not own an overlay region: it produces rows for the host
/// to paint (same contract as every view in this package) and exposes
/// [awaitDecision] driven by a [KeySource]. Defaults to `allow` highlighted;
/// ↓ moves to `deny`; every remembered-approval scope is its own row on the
/// first menu, deciding immediately — no submenu round-trip. `allowAlways` is
/// offered only when the tool's arguments parse (a mistrusted call is a bad
/// thing to blanket-allow).
class ApprovalDialog {
  int _selected = 0;
  bool _rememberMenu = false;
  bool _details = false;
  int _detailOffset = 0;
  int _maxDetailOffset = 0;
  int _previewOffset = 0;
  int _maxPreviewOffset = 0;
  int _pageSize = 1;
  bool _directoryScopeExplicit = false;
  final _selectedDirectories = <int>{};
  final _directoryOffers =
      <({String path, DirectoryAccess access, String source})>[];
  List<DirectoryGrantScope> _directoryScopes = const [
    DirectoryGrantScope.session
  ];
  DirectoryGrantScope _directoryScope = DirectoryGrantScope.workspace;
  // The folder-scope caption writes its own words; the enum names it cycles
  // through (session/workspace/global) should not leak into the label.
  static const _scopeWord = {
    DirectoryGrantScope.session: 'this session',
    DirectoryGrantScope.workspace: 'this workspace',
    DirectoryGrantScope.global: 'every workspace',
  };
  bool get _hasDirectoryOffers =>
      _directoryOffers.isNotEmpty &&
      ask?.confirmation != true &&
      call?.argumentsParseError == null;

  bool get _onDirectoryCheckbox => _choices[_selected].startsWith('directory ');
  bool get _onScope => _choices[_selected] == 'grant scope';

  /// The pending tool call, when the question came from one. A permission
  /// ask straight from the sandbox has no call — only [ask].
  ToolUse? call;

  /// When the pending question is a permission ask: the operation, the
  /// resolved path and the reason, rendered under the header. Null for a
  /// plain tool-call dialog.
  ApprovalAskContext? ask;

  bool get _hasPersistent =>
      ask?.confirmation != true &&
      ask?.details['persistent_command_approval'] == true;

  /// The remembered-approval scopes this dialog can offer, when any: session
  /// always, workspace and global only when the ask says they persist.
  List<ApprovalDecision> get _scopeChoices => [
        ApprovalDecision.allowAlways,
        if (_hasPersistent) ...[
          ApprovalDecision.allowWorkspace,
          ApprovalDecision.allowGlobal
        ],
      ];

  bool get _hasAlways =>
      ask?.confirmation != true && call?.argumentsParseError == null;
  bool get _hasCommandPattern =>
      ask?.confirmation != true &&
      _hasAlways &&
      ask?.details['command_pattern_target'] is String;

  ApprovalDialog(this.call, {this.ask}) {
    final offers = ask?.details['directory_accesses'];
    if (offers is List) {
      for (final offer in offers.take(32)) {
        if (offer is Map &&
            offer['path'] is String &&
            {'read', 'write'}.contains(offer['access'])) {
          _directoryOffers.add((
            path: offer['path'] as String,
            access: DirectoryAccess.values.byName(offer['access'] as String),
            source: offer['source'] == 'inferred' ? 'inferred' : 'verified'
          ));
        }
      }
    }
    final scopes = ask?.details['directory_grant_scopes'];
    if (scopes is List) {
      _directoryScopes = DirectoryGrantScope.values
          .where((scope) => scopes.contains(scope.name))
          .toList();
      if (_directoryScopes.isEmpty)
        _directoryScopes = const [DirectoryGrantScope.session];
    }
    if (!_directoryScopes.contains(_directoryScope))
      _directoryScope = _directoryScopes.first;
    if (ask?.details['directory_grant_required'] == true) {
      _selectedDirectories
          .addAll(List.generate(_directoryOffers.length, (index) => index));
    }
  }

  // An explicit folder scope overrides the approval scope. Otherwise rendering
  // and confirmation must derive the same scope from the selected decision.
  DirectoryGrantScope _directoryScopeFor(ApprovalDecision decision) =>
      _directoryScopeExplicit
          ? _directoryScope
          : switch (decision) {
              ApprovalDecision.allowWorkspace => DirectoryGrantScope.workspace,
              ApprovalDecision.allowGlobal => DirectoryGrantScope.global,
              _ => DirectoryGrantScope.session,
            };

  ApprovalOutcome _outcome(ApprovalDecision decision,
          {bool editCommandPattern = false}) =>
      ApprovalOutcome(decision,
          editCommandPattern: editCommandPattern,
          directoryGrants: {
            ApprovalDecision.allowAlways,
            ApprovalDecision.allowWorkspace,
            ApprovalDecision.allowGlobal
          }.contains(decision)
              ? List.unmodifiable([
                  for (final index in _selectedDirectories)
                    DirectoryAccessGrant(
                        _directoryOffers[index].path,
                        _directoryOffers[index].access,
                        _directoryScopeFor(decision))
                ])
              : const []);

  List<String> get _choices => ask?.confirmation == true
      ? ['Yes', 'No']
      : !_rememberMenu
          ? ['allow', 'deny', if (_hasAlways) 'remember']
          : [
              'allow always',
              if (_hasPersistent) 'allow workspace',
              if (_hasPersistent) 'allow global',
              if (_hasDirectoryOffers) ...[
                for (var i = 0; i < _directoryOffers.length; i++)
                  'directory $i',
                'grant scope',
              ],
              if (_hasCommandPattern) 'edit command pattern',
              'back',
            ];

  void _openRemember() {
    _details = false;
    _rememberMenu = true;
    _selected = 0;
    _directoryScope = DirectoryGrantScope.session;
    _directoryScopeExplicit = false;
    // Remember the requested directories, never extra model-inferred folders.
    final invocation = ask?.details['invocation_directory_access'];
    if (invocation is Map || ask?.details['directory_grant_required'] == true) {
      for (var i = 0; i < _directoryOffers.length; i++) {
        final offer = _directoryOffers[i];
        if (ask?.details['directory_grant_required'] == true ||
            (invocation is Map ? invocation[offer.access.name] as List? : null)
                    ?.contains(offer.path) ==
                true) {
          _selectedDirectories.add(i);
        }
      }
    }
  }

  bool _navigateRemember() {
    if (_choices[_selected] == 'remember') {
      _openRemember();
      return true;
    }
    if (_choices[_selected] == 'back') {
      _rememberMenu = false;
      _selected = 0;
      _selectedDirectories.clear();
      return true;
    }
    return false;
  }

  ApprovalDecision decisionFor(int index) => switch (_choices[index]) {
        'allow always' => ApprovalDecision.allowAlways,
        'allow workspace' => ApprovalDecision.allowWorkspace,
        'allow global' => ApprovalDecision.allowGlobal,
        'allow' || 'Yes' => ApprovalDecision.allow,
        _ => ApprovalDecision.deny,
      };

  /// Input-anchored rows: context and navigation above the answer selector.
  /// The last row replaces the text input. On narrow screens the selected
  /// answer remains visible; Tab opens scrollable, unabridged details.
  List<RenderLine> rows(
      {int width = 80,
      int height = 1000,
      Theme theme = const Theme.defaults()}) {
    final chat = theme.chat;
    final ask = this.ask;
    if (call == null && ask == null) {
      throw StateError('an ApprovalDialog needs a call or an ask context');
    }
    final tool = ask?.details['tool'];
    final toolMap = tool is Map ? tool : const {};
    final name = call?.name ?? toolMap['name']?.toString() ?? ask?.op ?? '';
    final rawInput = call?.input ?? toolMap['input'];
    final input = rawInput is Map ? rawInput : const {};
    final description = ToolDescription.fromJson(ask?.details['description']);
    final scope = ask?.details['permission_scope'] ??
        ({'bash', 'exec'}.contains(name)
            ? 'command'
            : {'read', 'write', 'edit', 'ls', 'stat', 'glob'}.contains(name) ||
                    {'read', 'write'}.contains(ask?.op)
                ? 'file'
                : null);
    // Name the object a remembered approval covers: the plugin's label when
    // supplied, otherwise derived from the ask's scope. The [a]/[p]/[g] rows
    // all describe remembering this same object, so they share one phrase —
    // command asks say "this command", file asks say "this file".
    final scopeLabel = ask?.details['permission_scope_label'];
    final object = scopeLabel is String
        ? scopeLabel
        : switch (scope) {
            'file' => 'this file',
            'command' => 'this command',
            _ => 'matching calls',
          };
    final alwaysLabel = 'allow $object for this session';
    final label = ask?.confirmation == true
        ? ask!.title
        : description?.title ??
            switch (name) {
              'bash' => 'Run shell command',
              'exec' => 'Run program',
              'edit' => 'Edit file',
              'write' => 'Write file',
              'read' => 'Read file',
              _ => ask?.title ?? name,
            };
    if (width <= 0 || height <= 0) return [];
    RenderLine row(String text, [String? style]) => RenderLine(runs: [
          RenderRun(clipDialogText(_safe(text), width), style),
        ]);
    final denialReason = ask?.details['auto_approval_denial_reason'];
    final hasDenialReason =
        denialReason is String && denialReason.trim().isNotEmpty;
    final details = <String>[
      if (ask?.details['authorization_reason'] case final String why)
        'Why approval is needed: $why',
      if (ask?.details['access_requirements'] case final List requirements)
        for (final r in requirements)
          if (r is Map)
            '${r['granted'] == true ? 'Already permitted' : 'Requested'}: ${r['capability']} ${r['target']}',

      if (ask?.details['invocation_directory_access'] case final Map access)
        for (final kind in ['read', 'write'])
          if (access[kind] case final List paths)
            for (final path in paths)
              'This invocation: $kind access to $path${kind == 'write' ? ' (includes deletes)' : ''}',
      if (ask?.details['accesses'] case final List accesses)
        for (final access in accesses)
          if (access is Map && access['path'] is String)
            '${access['operation']}: ${access['path']} (${access['target_kind']}, ${access['source'] == 'inferred' ? 'inferred' : 'verified'})',
      // Plain sentences, not a coverage metric: a verified complete analysis
      // stays silent, and anything short of that is a warning the reader can
      // parse without knowing the classifier's vocabulary.
      if (ask?.details['access_coverage'] case final String coverage)
        if (coverage != 'complete')
          coverage == 'partial'
              ? '⚠ File analysis incomplete: may affect files not listed above'
              : '⚠ Could not determine which files this command touches'
        else if (ask?.details['access_coverage_source'] != 'verified')
          'Files: AI analysis · no other files detected',
      if (ask?.details['unresolved_accesses'] case final List unresolved)
        for (final item in unresolved) 'Not analyzed: $item',
      if (ask?.confirmation == true) ...[
        ask!.reason,
        if (description != null) ...[
          if (description.target.isNotEmpty &&
              !description.fields.containsKey('Command'))
            description.target,
          for (final entry in description.fields.entries)
            '${entry.key}: ${entry.value}',
          if (ask.details['cwd'] != null) 'Directory: ${ask.details['cwd']}',
        ],
      ] else ...[
        // Keep the classifier's concrete concern in the first preview row,
        // even when a short terminal has room for only one context row.
        // Tab still shows the full permission request and classifier details.
        if (name == 'bash' ||
            name == 'exec' ||
            description?.fields.containsKey('Command') == true) ...[
          'Directory: ${input['cwd'] ?? ask?.details['cwd'] ?? ask?.details['workspace'] ?? '.'}',
          if (input['env'] is Map && (input['env'] as Map).isNotEmpty)
            'Environment: ${(input['env'] as Map).length} override(s)',
          '',
          if (description?.fields['Command'] != null)
            description!.fields['Command']!
          else if (name == 'bash')
            '${input['command'] ?? ask?.path ?? ''}'
          else
            _argv(input, ask),
        ] else ...[
          if ((input['filePath'] ?? input['path']) != null || ask != null)
            description?.target ??
                '${(input['filePath'] ?? input['path']) ?? ask!.path}',
          if (description != null)
            for (final entry in description.fields.entries)
              '${entry.key}: ${entry.value}',
          if (name == 'write' && input['content'] is String)
            ..._diff(input['content'] as String, '+'),
          if (name == 'edit')
            ..._editDiff(
                (input['oldString'] ?? input['old_string'] ?? '').toString(),
                (input['newString'] ?? input['new_string'] ?? '').toString()),
        ],
        if (call?.argumentsParseError != null) call!.argumentsParseError!,
        if (ask != null && (_details || !hasDenialReason)) 'Why: ${ask.reason}',
        if (_hasAlways &&
            ask?.details['permission_scope_description'] is String)
          ask!.details['permission_scope_description'] as String
        else if (_hasAlways && scope == 'file')
          'Session approval covers only this file. Other files still ask.',
        if (_hasAlways &&
            ask?.details['permission_scope_description'] == null &&
            scope == 'command')
          'Session approval covers this exact command in this directory.',
      ],
      if (_details && ask?.details['mode'] != null)
        'Mode: ${ask!.details['mode']}',
      if (_details && ask?.details['auto_approval_classifier'] is Map) ...[
        ..._classifierDetails(ask!.details['auto_approval_classifier'] as Map),
      ],
      if (_details && input.isNotEmpty) ...[
        'Tool: $name',
        'Arguments',
        _pretty(input),
      ],
    ].map(_safe).toList();
    String? contentStyle(String detail) {
      if (name == 'edit' || name == 'write') {
        if (detail.startsWith('+ ')) return chat.green;
        if (detail.startsWith('- ')) return chat.red;
        if (detail.startsWith('  ') || detail == '⋯') return chat.dim;
      }
      if (detail.startsWith('Directory:') || detail.startsWith('Mode:')) {
        return chat.dim;
      }
      if (detail.startsWith('Why:') ||
          detail.startsWith('Environment:') ||
          detail.startsWith('⚠')) {
        return chat.yellow;
      }
      return null;
    }

    if (_details) {
      final lines = [
        for (final detail in details)
          for (final part in detail.split('\n'))
            for (final line in wrapDialogText(part, width))
              row(line, contentStyle(detail))
      ];
      final count = (height - 2).clamp(1, height);
      _pageSize = count;
      _maxDetailOffset = (lines.length - count).clamp(0, lines.length);
      _detailOffset = _detailOffset.clamp(0, _maxDetailOffset);
      return [
        if (height > 1)
          row('Details ${_detailOffset + 1}/${lines.length}',
              theme.dialog.confirm),
        for (final line in lines.skip(_detailOffset).take(count)) line,
        if (height > 2) row('↑↓ scroll · tab back · esc cancel', chat.dim),
      ].take(height).toList();
    }
    String choiceLabel(String choice) {
      if (choice.startsWith('directory ')) {
        final index = int.parse(choice.substring(10));
        final offer = _directoryOffers[index];
        // Indented: these rows modify the scope rows above (which folders a
        // remembered approval includes), they are not peer actions.
        return '  [${_selectedDirectories.contains(index) ? 'x' : ' '}] Allow all '
            '${offer.access == DirectoryAccess.read ? 'reads' : 'writes (including deletes)'} '
            'in ${offer.path}${offer.source == 'inferred' ? ' (inferred)' : ''} (Space)';
      }
      return switch (choice) {
        'Yes' => '[y] Yes',
        'No' => '[n] No',
        'allow' => ask?.details['directory_grant_required'] == true
            ? '[y] allow once and retry'
            : '[y] allow once',
        'deny' => '[n] deny',
        'remember' => '[a] Remember…',
        'back' => 'Back',
        'allow always' => '[a] $alwaysLabel',
        'allow workspace' => '[p] Remember $object for this workspace',
        'allow global' => '[g] Remember $object in every workspace',
        'edit command pattern' => '[e] Approve with an editable regex',
        // Not a decision row: the checked folders are saved when one of the
        // scope rows above is confirmed. This line only sets their scope,
        // so its label states that instead of implying it saves something.
        'grant scope' =>
          'Checked folders will be remembered: ${_scopeWord[_directoryScopeFor(decisionFor(_selected))]} (s/Enter)',
        _ => choice,
      };
    }

    final choices = _choices.map(choiceLabel).toList();
    RenderLine choice(int i, {bool compact = false}) => row(
        '${i == _selected ? '❯' : ' '} ${choices[i]}${compact ? ' (${i + 1}/${choices.length})' : ''}',
        i == _selected ? theme.dialog.confirm : null);
    if (height <= 3) {
      return [choice(_selected, compact: true)];
    }
    // Every answer gets its own row. Only very short terminals show the
    // selected answer alone, keeping one row for the request's context. A
    // pinned denial banner counts against the choices first: the warning
    // outranks the full answer list.
    final bannerLines = hasDenialReason && !_details
        ? (width < 48
            // Narrow terminal: one clipped row beats a banner that eats the
            // dialog; Tab still shows the full reason.
            ? [
                clipDialogText('Auto approver denied this: $denialReason',
                    (width - 4).clamp(1, width))
              ]
            : wrapDialogText('Auto approver denied this: $denialReason',
                (width - 2).clamp(1, width)))
        : const <String>[];
    final roomForChoices = (height - bannerLines.length - 3).clamp(0, 1000);
    final choiceRows = roomForChoices >= choices.length
        ? [for (var i = 0; i < choices.length; i++) choice(i)]
        : [choice(_selected, compact: true)];
    final preview = [
      for (final detail in details)
        for (final part in detail.split('\n'))
          for (final line in ask?.confirmation == true
              ? wrapDialogWords(part, (width - 2).clamp(1, width))
              : wrapDialogText(part, (width - 2).clamp(1, width)))
            row('│ $line', contentStyle(detail)),
    ];
    final bannerRows = bannerLines.length;
    final available =
        (height - choiceRows.length - 2 - bannerRows).clamp(0, preview.length);
    final paged = preview.length > available && available >= 2;
    final budget = available - (paged ? 1 : 0);
    _pageSize = budget > 0 ? budget : 1;
    _maxPreviewOffset = (preview.length - budget).clamp(0, preview.length);
    _previewOffset = _previewOffset.clamp(0, _maxPreviewOffset);
    return [
      row('┌ $label · awaiting approval', theme.dialog.confirm),
      // The auto-approver's reason for refusing is the decision the user must
      // weigh in on: pin it under the header, unpaged, and style it as a
      // warning so it never hides among the preview rows or pages away.
      for (final line in bannerLines) row('│ ⚠ $line', chat.yellow),
      ...preview.skip(_previewOffset).take(budget),
      if (paged)
        row('│ Preview ${_previewOffset + 1}–${_previewOffset + budget}/${preview.length} · PgUp/PgDn or wheel',
            chat.dim),
      row(
          width >= 56
              ? '│ ↑↓ choose · Enter confirm · Tab details · Esc cancel'
              : '│ ↑↓ · Enter · Tab details · Esc cancel',
          chat.dim),
      ...choiceRows,
    ].take(height).toList();
  }

  /// Apply one navigation key; returns true when the selection changed.
  bool handleKey(ApprovalKey key) {
    if (key == ApprovalKey.confirm && !_details && _navigateRemember())
      return true;
    if (key == ApprovalKey.always && !_rememberMenu && _hasAlways) {
      _openRemember();
      return true;
    }
    if (_rememberMenu &&
        _hasDirectoryOffers &&
        (key == ApprovalKey.directoryScope ||
            key == ApprovalKey.confirm && _onScope && !_details)) {
      final scope = _directoryScopeFor(decisionFor(_selected));
      _directoryScopeExplicit = true;
      _directoryScope = _directoryScopes[
          (_directoryScopes.indexOf(scope) + 1) % _directoryScopes.length];
      return true;
    }
    if (_rememberMenu && _hasDirectoryOffers) {
      int? index;
      if ((key == ApprovalKey.toggleDirectory ||
              key == ApprovalKey.confirm && !_details) &&
          _choices[_selected].startsWith('directory ')) {
        index = int.parse(_choices[_selected].substring(10));
      } else if (key == ApprovalKey.toggleReadDirectory ||
          key == ApprovalKey.toggleWriteDirectory) {
        final access = key == ApprovalKey.toggleReadDirectory
            ? DirectoryAccess.read
            : DirectoryAccess.write;
        final match =
            _directoryOffers.indexWhere((offer) => offer.access == access);
        if (match >= 0) index = match;
      }
      if (index != null) {
        if (!_selectedDirectories.remove(index))
          _selectedDirectories.add(index);
        return true;
      }
    }
    if ({
      ApprovalKey.pageUp,
      ApprovalKey.pageDown,
      ApprovalKey.scrollUp,
      ApprovalKey.scrollDown
    }.contains(key)) {
      final backwards =
          key == ApprovalKey.pageUp || key == ApprovalKey.scrollUp;
      final amount = key == ApprovalKey.pageUp || key == ApprovalKey.pageDown
          ? _pageSize
          : 3;
      final delta = backwards ? -amount : amount;
      if (_details) {
        _detailOffset = (_detailOffset + delta).clamp(0, _maxDetailOffset);
      } else {
        _previewOffset = (_previewOffset + delta).clamp(0, _maxPreviewOffset);
      }
      return true;
    }
    if (key == ApprovalKey.details ||
        (_details && key == ApprovalKey.confirm)) {
      _details = !_details;
      return true;
    }
    if (_details && (key == ApprovalKey.up || key == ApprovalKey.down)) {
      _detailOffset = (_detailOffset + (key == ApprovalKey.up ? -1 : 1))
          .clamp(0, _maxDetailOffset);
      return true;
    }
    switch (key) {
      case ApprovalKey.pageUp:
      case ApprovalKey.pageDown:
      case ApprovalKey.scrollUp:
      case ApprovalKey.scrollDown:
      case ApprovalKey.allow:
      case ApprovalKey.deny:
      case ApprovalKey.workspace:
      case ApprovalKey.global:
      case ApprovalKey.always:
      case ApprovalKey.editCommandPattern:
      case ApprovalKey.details:
      case ApprovalKey.toggleReadDirectory:
      case ApprovalKey.toggleWriteDirectory:
      case ApprovalKey.toggleDirectory:
      case ApprovalKey.directoryScope:
        return false;
      case ApprovalKey.up:
        if (_selected > 0) {
          _selected--;
          return true;
        }
        return false;
      case ApprovalKey.down:
        if (_selected < _choices.length - 1) {
          _selected++;
          return true;
        }
        return false;
      case ApprovalKey.confirm:
      case ApprovalKey.cancel:
        return false;
    }
  }

  /// The decision the current selection maps to.
  ApprovalOutcome get current {
    final choice = _choices[_selected];
    return _outcome(decisionFor(_selected),
        editCommandPattern: choice == 'edit command pattern');
  }

  /// The decision for the scope matching [shortcut], when the ask offers
  /// persistent scopes. Returns null when that scope is not offered.
  ApprovalOutcome? scopeDecision(ApprovalKey shortcut) {
    final target = switch (shortcut) {
      ApprovalKey.always => 0,
      ApprovalKey.workspace => 1,
      ApprovalKey.global => 2,
      _ => -1,
    };
    if (!_rememberMenu || target < 0 || target >= _scopeChoices.length)
      return null;
    return _outcome(_scopeChoices[target]);
  }

  /// Drive the dialog from [keys]: arrows move, Enter confirms, Esc/source
  /// close cancels (a denial with reason `'cancelled'`). Resolves when a
  /// decision is reached; never throws on an empty source. [onKey] runs
  /// after each selection change, so a host can repaint the question.
  /// [onAnyKey] additionally runs for keys the dialog consumes without
  /// acting on (ordinary typing, pastes) — so a host can repaint and the
  /// dialog never looks frozen while it owns the keyboard.
  Future<ApprovalOutcome> awaitDecision(KeySource keys,
      {void Function()? onKey, void Function()? onAnyKey}) async {
    while (true) {
      final key = await keys.next();
      onAnyKey?.call();
      switch (key) {
        case ApprovalKey.allow:
          return _outcome(ApprovalDecision.allow);
        case ApprovalKey.deny:
          return const ApprovalOutcome(ApprovalDecision.deny);
        case ApprovalKey.workspace:
        case ApprovalKey.global:
          // Scope shortcuts are active only inside Remember.
          final outcome = scopeDecision(key!);
          if (outcome != null) return outcome;
        case ApprovalKey.always:
          if (_hasAlways) {
            if (!_rememberMenu) {
              _openRemember();
              onKey?.call();
            } else {
              return scopeDecision(ApprovalKey.always)!;
            }
          }
        case ApprovalKey.editCommandPattern:
          if (_rememberMenu && _hasCommandPattern) {
            return const ApprovalOutcome(ApprovalDecision.deny,
                editCommandPattern: true);
          }
        case ApprovalKey.pageUp:
        case ApprovalKey.pageDown:
        case ApprovalKey.scrollUp:
        case ApprovalKey.scrollDown:
        case ApprovalKey.up:
        case ApprovalKey.down:
        case ApprovalKey.details:
        case ApprovalKey.toggleReadDirectory:
        case ApprovalKey.toggleWriteDirectory:
        case ApprovalKey.toggleDirectory:
        case ApprovalKey.directoryScope:
          handleKey(key!);
          onKey?.call();
        case ApprovalKey.confirm:
          if (!_details && _navigateRemember()) {
            onKey?.call();
            continue;
          }
          if (!_details && !_onDirectoryCheckbox && !_onScope) {
            return current;
          }
          handleKey(key!);
          onKey?.call();
        case ApprovalKey.cancel:
          if (_rememberMenu) {
            _rememberMenu = false;
            _selected = 0;
            _selectedDirectories.clear();
            onKey?.call();
            continue;
          }
          return const ApprovalOutcome(
            ApprovalDecision.deny,
            reason: 'cancelled',
          );
        case null:
          return const ApprovalOutcome(
            ApprovalDecision.deny,
            reason: 'cancelled',
          );
      }
    }
  }
}

String _inlineArgs(Map<String, dynamic> input) {
  if (input.isEmpty) return '';
  return input.entries
      .map((e) => '${e.key}: ${jsonEncode(e.value)}')
      .join(', ');
}

String _pretty(Object? value) {
  Object? redact(Object? v) => switch (v) {
        Map v => {
            for (final entry in v.entries)
              '${entry.key}': RegExp(
                          r'(password|secret|token|api[_-]?key|authorization)',
                          caseSensitive: false)
                      .hasMatch('${entry.key}')
                  ? '[redacted]'
                  : redact(entry.value)
          },
        List v => v.map(redact).toList(),
        _ => v,
      };
  return const JsonEncoder.withIndent('  ').convert(redact(value));
}

// Render controls literally; tool arguments must never execute terminal escapes.
String _safe(String value) => value.replaceAllMapped(
    RegExp(r'[\x00-\x09\x0b-\x1f\x7f]'),
    (m) => '\\x${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}');

Iterable<String> _diff(String text, String prefix) =>
    text.split('\n').map((line) => '$prefix $line');

Iterable<String> _classifierDetails(Map details) sync* {
  if (details['model'] != null)
    yield 'Approval classifier: ${details['model']}';
  if (details['attempts'] != null)
    yield 'Classifier attempts: ${details['attempts']}';
  if (details['answer_characters'] != null)
    yield 'Classifier answer: ${details['answer_characters'] is int ? formatInteger(details['answer_characters'] as int) : details['answer_characters']} characters';
  if (details['reasoning_characters'] != null)
    yield 'Classifier reasoning: ${details['reasoning_characters'] is int ? formatInteger(details['reasoning_characters'] as int) : details['reasoning_characters']} characters';
  if (details['stop_reason'] != null)
    yield 'Classifier completion: ${details['stop_reason']}';
}

String _argv(Map input, ApprovalAskContext? ask) {
  final executable =
      input['program'] ?? input['executable'] ?? ask?.details['executable'];
  final args = input['args'] ?? input['arguments'] ?? ask?.details['arguments'];
  if (executable == null)
    return ask?.path ?? _inlineArgs(Map<String, dynamic>.from(input));
  String quote(Object? v) {
    final text = _safe(v.toString());
    return RegExp(r'^[a-zA-Z0-9_./:=+-]+$').hasMatch(text)
        ? text
        : "'${text.replaceAll("'", "'\\''")}'";
  }

  return [executable, if (args is List) ...args].map(quote).join(' ');
}

// Keep shared lines as context rather than presenting them as removed/added.
Iterable<String> _editDiff(String before, String after) sync* {
  final old = before.split('\n');
  final updated = after.split('\n');
  var prefix = 0;
  while (prefix < old.length &&
      prefix < updated.length &&
      old[prefix] == updated[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < old.length - prefix &&
      suffix < updated.length - prefix &&
      old[old.length - suffix - 1] == updated[updated.length - suffix - 1]) {
    suffix++;
  }
  if (prefix > 3) yield '⋯';
  for (final line in old.take(prefix).skip(prefix > 3 ? prefix - 3 : 0)) {
    yield '  $line';
  }
  for (final line in old.skip(prefix).take(old.length - prefix - suffix)) {
    yield '- $line';
  }
  for (final line
      in updated.skip(prefix).take(updated.length - prefix - suffix)) {
    yield '+ $line';
  }
  for (final line in updated.skip(updated.length - suffix).take(3)) {
    yield '  $line';
  }
  if (suffix > 3) yield '⋯';
}
