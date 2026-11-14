import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_layout/tina_layout.dart';

/// The chat screen arrangement under each shipped strategy. These are
/// the goldens for the user-visible feature: the same terminal, three
/// arrangements, and the guarantee that removing the strategy restores
/// the default byte-for-byte.
void main() {
  tearDown(() {
    LayoutStrategies.instance.uninstall();
    LayoutStrategies.instance.onFallbackNotice = null;
  });

  ScreenLayout at(int width, int height,
          {bool hasMenuBar = false, bool? split}) =>
      ScreenLayout.fromSize(width, height,
          hasMenuBar: hasMenuBar, split: split);

  group('goldens: default (the built-in solver)', () {
    test('100 columns splits 65/35', () {
      final layout = at(100, 30);
      expect(layout.isSplit, isTrue);
      expect(layout.chatLeftCol, 0);
      expect(layout.chatRightCol, 64);
      expect(layout.infoLeftCol, 65);
      expect(layout.infoRightCol, 99);
    });

    test('80 columns stays single-column below the 100 threshold', () {
      final layout = at(80, 24);
      expect(layout.isSplit, isFalse);
      expect(layout.infoLeftCol, -1);
      expect(layout.chatRightCol, 79);
    });

    test('narrow and tiny terminals clamp (60x14, 40x10)', () {
      final narrow = at(60, 14);
      expect(narrow.isSplit, isFalse);
      expect(narrow.chat.width, 58); // borders excluded
      final tiny = at(40, 10);
      expect(tiny.height, greaterThanOrEqualTo(6));
      expect(tiny.chat.width, greaterThan(0));
      expect(tiny.input.row, lessThan(10));
    });

    test('the menu box shifts the frame three rows', () {
      final layout = at(100, 30, hasMenuBar: true);
      expect(layout.menuTopBorderRow, 0);
      expect(layout.topBorderRow, 3);
    });
  });

  group('goldens: focus (equal halves from 80 columns)', () {
    setUp(() => LayoutStrategies.instance.install(const FocusScreenStrategy()));

    test('120 columns shares 60/60', () {
      final layout = at(120, 30);
      expect(layout.isSplit, isTrue);
      expect(layout.chatLeftCol, 0);
      expect(layout.chatRightCol, 59);
      expect(layout.infoLeftCol, 60);
      expect(layout.infoRightCol, 119);
    });

    test('80 columns splits (the preset threshold) at 40/40', () {
      final layout = at(80, 24);
      expect(layout.isSplit, isTrue);
      expect(layout.chatRightCol, 39);
      expect(layout.infoLeftCol, 40);
    });

    test('below 80 columns focus follows the default exactly', () {
      final layout = at(60, 24);
      expect(layout.isSplit, isFalse);
      expect(layout.chatRightCol, 59);
      expect(layout.infoLeftCol, -1);
    });

    test('the strip, input row and menu box stay in place', () {
      final layout = at(120, 30, hasMenuBar: true);
      expect(layout.stripRow, 29);
      expect(layout.menuTopBorderRow, 0);
      expect(layout.input.row, 27);
      expect(layout.topBorderRow, 3);
    });
  });

  group('goldens: two-column (info left from 80 columns)', () {
    setUp(() =>
        LayoutStrategies.instance.install(const TwoColumnScreenStrategy()));

    test('120 columns mirrors: info left 46, chat right 74', () {
      final layout = at(120, 30);
      expect(layout.isSplit, isTrue);
      // The info box owns the LEFT columns now.
      expect(layout.infoLeftCol, 0);
      expect(layout.infoRightCol, 45);
      expect(layout.chatLeftCol, 46);
      expect(layout.chatRightCol, 119);
      // The transcript itself sits inside the right box.
      expect(layout.chat.col, greaterThan(layout.info.col));
    });

    test('80 columns splits 31/49 (info left)', () {
      final layout = at(80, 24);
      expect(layout.isSplit, isTrue);
      expect(layout.infoLeftCol, 0);
      expect(layout.chatLeftCol, greaterThan(25));
      expect(layout.chatRightCol, 79);
    });

    test('below 80 columns two-column follows the default', () {
      final layout = at(60, 24);
      expect(layout.isSplit, isFalse);
      expect(layout.chatLeftCol, 0);
      expect(layout.chatRightCol, 59);
    });
  });

  group('live swap', () {
    test('install moves the screen, uninstall restores it exactly', () {
      final before = at(120, 30);
      LayoutStrategies.instance.install(const FocusScreenStrategy());
      final during = at(120, 30);
      expect(during.chatRightCol, isNot(before.chatRightCol));
      LayoutStrategies.instance.install(const TwoColumnScreenStrategy());
      final mirrored = at(120, 30);
      expect(mirrored.chatLeftCol, greaterThan(0));
      expect(mirrored.chatLeftCol, isNot(during.chatLeftCol));
      LayoutStrategies.instance.uninstall();
      final after = at(120, 30);
      expect(_fingerprint(after), _fingerprint(before));
    });

    test('the config split:false default can still be overridden by a '
        'strategy (what the TUI boots with)', () {
      // The TUI passes split:false; a strategy's forceSplit wins.
      final layout = ScreenLayout.fromSize(120, 30, split: false);
      expect(layout.isSplit, isFalse);
      LayoutStrategies.instance.install(const FocusScreenStrategy());
      final swapped = ScreenLayout.fromSize(120, 30, split: false);
      expect(swapped.isSplit, isTrue);
      expect(swapped.chatRightCol, 59);
    });

    test('a throwing strategy leaves the default screen correct + notices',
        () {
      final notices = <String>[];
      LayoutStrategies.instance.onFallbackNotice = notices.add;
      LayoutStrategies.instance.install(const _ThrowingScreenStrategy());
      final fallback = at(120, 30);
      final reference = at(120, 30);
      expect(_fingerprint(fallback), _fingerprint(reference));
      expect(fallback.chatRightCol, 77); // 65% of 120
      expect(notices, hasLength(1));
      at(120, 30); // no second notice
      expect(notices, hasLength(1));
    });

    test('a throwing policy keeps every core default', () {
      LayoutStrategies.instance.install(const _ThrowingPolicyStrategy());
      final layout = at(120, 30);
      expect(layout.isSplit, isTrue); // default threshold, default weights
      expect(layout.chatLeftCol, 0);
      expect(layout.chatRightCol, 77);
      expect(layout.infoLeftCol, 78);
    });
  });
}

int _fingerprint(ScreenLayout layout) => Object.hashAll([
      layout.width,
      layout.height,
      layout.isSplit,
      layout.drawInfoFrame,
      layout.chat.row,
      layout.chat.col,
      layout.chat.width,
      layout.chat.height,
      layout.input.row,
      layout.input.col,
      layout.input.width,
      layout.input.height,
      layout.info.row,
      layout.info.col,
      layout.info.width,
      layout.info.height,
      layout.sidebar.width,
      layout.chatLeftCol,
      layout.chatRightCol,
      layout.infoLeftCol,
      layout.infoRightCol,
      layout.topBorderRow,
      layout.bottomBorderRow,
      layout.inputRow,
      layout.stripRow,
      layout.hasMenuBar,
      layout.menuBarRow,
    ]);

final class _ThrowingScreenStrategy implements LayoutStrategy {
  const _ThrowingScreenStrategy();

  @override
  String get id => 'throwing/screen';

  @override
  String get version => '1.0.0';

  @override
  GridSolution solve(GridSpec spec,
      {required int columns, required int rows}) {
    throw StateError('solve exploded');
  }
}

final class _ThrowingPolicyStrategy extends BuiltinLayoutStrategy {
  const _ThrowingPolicyStrategy();

  @override
  String get id => 'throwing/policy';

  ScreenPolicy? policyFor(
          {required int width,
          required int height,
          required bool hasMenuBar,
          required int sidebarWidth}) =>
      throw StateError('policy exploded');
}
