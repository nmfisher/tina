import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/tui/settings_panel.dart';
import 'package:tina_console/tina_console.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/overlay_fixtures.dart';

void main() {
  final tmp = TempTinaDir();
  final canned = CannedEvents();
  setUp(() {
    tmp.setUp('tina_typesafe_ui_');
    canned.clear();
  });
  tearDown(tmp.tearDown);

  Future<UserConfig?> run({
    UserConfig initial = UserConfig.empty,
    Screen? screen,
    Map<String, String> env = const {},
  }) {
    final target = screen ?? fakeScreen();
    return runTypeSafePanel(
      screen: target,
      editor: LineEditor(screen: target),
      env: env,
      tinaDir: tmp.dir,
      initial: initial,
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
  }

  test(
    'settings index exposes Typesafe and saves key separately from providers',
    () async {
      final screen = fakeScreen();
      canned.events = [
        ArrowKey(ArrowDirection.down),
        ArrowKey(ArrowDirection.down),
        ArrowKey(ArrowDirection.down),
        ControlKey(ControlCode.enter),
        PasteInput('my-typesafe-key\n'),
        ControlKey(ControlCode.enter),
        EscapeKey(),
      ];
      final wrote = await runSettingsPanel(
        screen: screen,
        editor: LineEditor(screen: screen),
        registry: setupRegistry(),
        env: const {},
        tinaDir: tmp.dir,
        readEvent: canned.readEvent,
      ).timeout(overlayTimeout);
      expect(wrote?.typeSafe?.apiKey, 'my-typesafe-key');
      expect(wrote?.providers, isEmpty);
    },
  );

  test(
    'existing key is masked; first paste replaces instead of appending',
    () async {
      const initial = UserConfig(
        typeSafe: TypeSafeSettings(apiKey: 'old-secret', model: 'pinned'),
        defaultProvider: 'alpha',
      );
      writeUserConfig(initial, env: const {}, tinaDir: tmp.dir);
      final io = FakeStdio()..hasTerminalValue = false;
      addTearDown(() {
        io.close();
      });
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24, hasMenuBar: false),
      );
      canned.events = [PasteInput('new-secret'), ControlKey(ControlCode.enter)];
      final wrote = await run(initial: initial, screen: screen);
      expect(wrote?.typeSafe?.apiKey, 'new-secret');
      expect(wrote?.typeSafe?.model, 'pinned');
      expect(wrote?.defaultProvider, 'alpha');
      expect(io.written.toString(), isNot(contains('old-secret')));
      expect(io.written.toString(), isNot(contains('new-secret')));
      expect(io.written.toString(), contains('********'));
    },
  );

  test('typed key appends after replacement and supports backspace', () async {
    canned.events = [
      CharInput('abc'),
      ControlKey(ControlCode.backspace),
      CharInput('d'),
      ControlKey(ControlCode.enter),
    ];
    expect((await run())?.typeSafe?.apiKey, 'abd');
  });

  test(
    'Delete clears stored key and does not copy the environment key to disk',
    () async {
      const initial = UserConfig(typeSafe: TypeSafeSettings(apiKey: 'old'));
      writeUserConfig(initial, env: const {}, tinaDir: tmp.dir);
      canned.events = [
        EditingKey(EditingAction.delete),
        ControlKey(ControlCode.enter),
      ];
      await run(
        initial: initial,
        env: {'TYPESAFE_API_KEY': 'environment-secret'},
      );
      final contents = userConfigFile(
        const {},
        tinaDir: tmp.dir,
      ).readAsStringSync();
      expect(contents, isNot(contains('old')));
      expect(contents, isNot(contains('environment-secret')));
      expect(contents, isNot(contains('[typesafe]')));
    },
  );

  for (final cancel in [EscapeKey(), ControlKey(ControlCode.ctrlC)]) {
    test('$cancel cancels edits without saving', () async {
      canned.events = [PasteInput('never-saved'), cancel];
      expect(await run(), isNull);
      expect(userConfigFile(const {}, tinaDir: tmp.dir).existsSync(), isFalse);
    });
  }

  test(
    'invalid control-character paste is not rendered or persisted',
    () async {
      final io = FakeStdio()..hasTerminalValue = false;
      addTearDown(() {
        io.close();
      });
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24, hasMenuBar: false),
      );
      canned.events = [
        PasteInput('secret\nInjected: value'),
        PasteInput('valid'),
        ControlKey(ControlCode.enter),
      ];
      expect((await run(screen: screen))?.typeSafe?.apiKey, 'valid');
      expect(io.written.toString(), contains('Invalid key'));
      expect(io.written.toString(), isNot(contains('secret')));
      expect(io.written.toString(), isNot(contains('Injected')));
    },
  );

  test('write failure stays in the modal and remains cancellable', () async {
    Directory('${tmp.dir.path}/config').createSync();
    final io = FakeStdio()..hasTerminalValue = false;
    addTearDown(() {
      io.close();
    });
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(80, 24, hasMenuBar: false),
    );
    canned.events = [
      PasteInput('not-leaked'),
      ControlKey(ControlCode.enter),
      EscapeKey(),
    ];
    expect(await run(screen: screen), isNull);
    expect(io.written.toString(), contains('Could not save'));
    expect(io.written.toString(), isNot(contains('not-leaked')));
  });

  test('tiny dimensions do not crash or save hidden edits', () async {
    for (final size in [(1, 1), (10, 4), (23, 7)]) {
      canned.clear();
      canned.events = [
        PasteInput('hidden'),
        ControlKey(ControlCode.enter),
        EscapeKey(),
      ];
      expect(
        await run(
          screen: fakeScreen(columns: size.$1, lines: size.$2),
        ),
        isNull,
      );
    }
    expect(userConfigFile(const {}, tinaDir: tmp.dir).existsSync(), isFalse);
  });
}
