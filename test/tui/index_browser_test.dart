import 'dart:async';

import 'package:test/test.dart';
import 'package:tina/tui/index_browser.dart';
import 'package:tina_app/classification.dart';
import 'package:tina_console/tina_console.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/overlay_fixtures.dart';

IndexView fixture() => IndexView({
  for (final path in ['.', 'src', 'src/nested'])
    path: IndexDirectory(
      path,
      path == '.'
          ? ['src']
          : path == 'src'
          ? ['src/nested']
          : [],
      {
        for (final kind in indexKinds)
          kind: const IndexResult(IndexState.missing, 'No result.'),
      },
    ),
});

void main() {
  test('load-more rows fetch another page and details are lazy', () async {
    var pages = 0;
    var details = 0;
    final root = fixture().directories['.']!;
    root.children.clear();
    root.hasMore = true;
    final view = IndexView(
      {'.': root},
      children: (path, offset, limit) async {
        pages++;
        expect(path, '.');
        expect(offset, 0);
        return [
          IndexDirectory('src', [], fixture().directories['src']!.results),
        ];
      },
      details: (path) async {
        details++;
        return fixture().directories[path]!;
      },
    );
    final screen = fakeScreen();
    final events = CannedEvents()
      ..events = [
        ArrowKey(ArrowDirection.down), // load more
        ControlKey(ControlCode.enter), // fetch and select src
        ControlKey(ControlCode.enter), // details
        ControlKey(ControlCode.enter), // tree
        ControlKey(ControlCode.enter), // cached details
        EscapeKey(),
      ];
    await runIndexBrowser(
      screen: screen,
      editor: LineEditor(screen: screen),
      view: view,
      readEvent: events.readEvent,
    ).timeout(overlayTimeout);
    expect(pages, 1);
    expect(details, 1);
    expect(root.children, ['src']);
  });

  test(
    'global cancellation interrupts a stalled database detail read',
    () async {
      final cancel = Completer<void>();
      final view = IndexView(
        fixture().directories,
        details: (_) {
          cancel.complete();
          return Completer<IndexDirectory>().future;
        },
      );
      final screen = fakeScreen();
      await runIndexBrowser(
        screen: screen,
        editor: LineEditor(screen: screen),
        view: view,
        cancelSignal: cancel.future,
        readEvent: () async => ControlKey(ControlCode.enter),
      ).timeout(overlayTimeout);
    },
  );

  test(
    'tree navigation, details and wheel repaint without writing chat',
    () async {
      final screen = fakeScreen(columns: 120);
      final io = screen.io as FakeStdio;
      final chatBefore = screen.chat.snapshotLines();
      final events = [
        ArrowKey(ArrowDirection.down),
        ArrowKey(ArrowDirection.right),
        ArrowKey(ArrowDirection.down),
        ControlKey(ControlCode.enter),
        ScrollEvent(up: false),
        ControlKey(ControlCode.enter),
        ArrowKey(ArrowDirection.left),
        EscapeKey(),
      ];
      var index = 0;
      await runIndexBrowser(
        screen: screen,
        editor: LineEditor(screen: screen),
        view: fixture(),
        readEvent: () async {
          if (index == 3) expect(io.written.toString(), contains('nested/'));
          if (index == 4)
            expect(io.written.toString(), contains('Index — src/nested'));
          return events[index++];
        },
      ).timeout(overlayTimeout);
      expect(index, events.length);
      expect(screen.chat.snapshotLines(), chatBefore);
    },
  );

  test(
    'cancel closes a pending reader and tiny screens are supported',
    () async {
      final screen = fakeScreen(columns: 10, lines: 3);
      final cancel = Completer<void>();
      final pending = runIndexBrowser(
        screen: screen,
        editor: LineEditor(screen: screen),
        view: fixture(),
        cancelSignal: cancel.future,
        readEvent: () {
          cancel.complete();
          return Completer<InputEvent>().future;
        },
      );
      await pending.timeout(overlayTimeout);
    },
  );
}
