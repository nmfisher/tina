import 'package:tina_engine/tina_engine.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/tui/prompts_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// Drives [runPromptsOverlay] with canned [InputEvent]s against a Screen over
/// [FakeStdio]. Asserts on the written config, not the pixels.
void main() {
  final tmp = TempTinaDir();
  final canned = CannedEvents();

  setUp(() {
    tmp.setUp('tina_prompts_');
    canned.clear();
  });
  tearDown(tmp.tearDown);

  Future<UserConfig?> run(Screen screen, {UserConfig? initial}) =>
      runPromptsOverlay(
        screen: screen,
        editor: LineEditor(screen: screen),
        pipeline: defaultPipeline,
        env: const {},
        tinaDir: tmp.dir,
        readEvent: canned.readEvent,
        initial: initial,
      );

  test('edit the main agent prompt and save → writes [prompts.main]', () async {
    final screen = fakeScreen(columns: 90, lines: 28);
    // Focus starts on 'main'. Enter opens the editor (seeded with the default);
    // type a marker; Ctrl-S saves; Esc closes.
    canned.events = [
      ControlKey(ControlCode.enter), // edit main
      CharInput(' MINE'), // append a marker to the seeded identity
      ControlKey(ControlCode.ctrlS), // save
      EscapeKey(), // close
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.prompts.containsKey('main'), isTrue);
    expect(cfg.prompts['main']!, contains('MINE'));
    expect(cfg.prompts['main']!,
        isNot(equals(defaultPipeline.mainRole.promptIdentity)));
    // Round-trips through the file.
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.prompts['main'], cfg.prompts['main']);
  });

  test('Esc with no edits → nothing written', () async {
    final screen = fakeScreen(columns: 90, lines: 28);
    canned.events = [EscapeKey()];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNull);
    expect(userConfigFile(const {}, tinaDir: tmp.dir).existsSync(), isFalse);
  });

  test('reset clears an existing override', () async {
    final screen = fakeScreen(columns: 90, lines: 28);
    final initial = const UserConfig(prompts: {'research': 'custom research'});
    // research is at index 1 (after main): down once, then 'r' to reset, Esc.
    canned.events = [
      ArrowKey(ArrowDirection.down),
      CharInput('r'),
      EscapeKey(),
    ];
    final cfg = await run(screen, initial: initial).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.prompts.containsKey('research'), isFalse);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.prompts, isEmpty);
  });

  test('saving an edit equal to the default drops the override', () async {
    final screen = fakeScreen(columns: 90, lines: 28);
    // Edit main (seeded with the default), save without changes → text equals
    // the default → not stored. No net change → null.
    canned.events = [
      ControlKey(ControlCode.enter), // edit main
      ControlKey(ControlCode.ctrlS), // save (unchanged == default)
      EscapeKey(),
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNull);
  });

  test('Esc in the editor discards the in-progress edit', () async {
    final screen = fakeScreen(columns: 90, lines: 28);
    // Edit main, type, Esc (cancel editor — not Ctrl-S), Esc (close). The edit
    // was never saved, so overrides are unchanged → null.
    canned.events = [
      ControlKey(ControlCode.enter), // edit main
      CharInput(' NEVERMIND'),
      EscapeKey(), // discard editor, back to role list
      EscapeKey(), // close
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNull);
  });

  test('multiple roles edited in one session all write', () async {
    final screen = fakeScreen(columns: 90, lines: 28);
    // main (index 0): edit + save. Then down to research (1): edit + save. Esc.
    canned.events = [
      ControlKey(ControlCode.enter), // edit main
      CharInput(' MAINX'),
      ControlKey(ControlCode.ctrlS),
      ArrowKey(ArrowDirection.down), // to research
      ControlKey(ControlCode.enter), // edit research
      CharInput(' RESX'),
      ControlKey(ControlCode.ctrlS),
      EscapeKey(),
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.prompts['main']!, contains('MAINX'));
    expect(cfg.prompts['research']!, contains('RESX'));
  });

  test('preserves the rest of the config when writing prompts', () async {
    final screen = fakeScreen(columns: 90, lines: 28);
    final initial = const UserConfig(
      defaultProvider: 'anthropic',
      defaultModel: 'claude-sonnet-4-6',
      tiers: {'heavy': 'anthropic/claude-sonnet-4-6'},
    );
    canned.events = [
      ControlKey(ControlCode.enter), // edit main
      CharInput(' X'),
      ControlKey(ControlCode.ctrlS),
      EscapeKey(),
    ];
    final cfg = await run(screen, initial: initial).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    // Unrelated sections survive the prompts write.
    expect(cfg!.defaultProvider, 'anthropic');
    expect(cfg.defaultModel, 'claude-sonnet-4-6');
    expect(cfg.tiers, {'heavy': 'anthropic/claude-sonnet-4-6'});
    expect(cfg.prompts['main']!, contains(' X'));
  });
}
