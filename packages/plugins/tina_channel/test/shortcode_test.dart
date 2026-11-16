import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';

/// A scripted [Random]: nextInt plays back [draws] in order, then
/// falls back to a real source. Deterministic collision scenarios.
final class ScriptedRandom implements Random {
  ScriptedRandom(this.draws) : _fallback = Random(99);
  final List<int> draws;
  final Random _fallback;
  var _used = 0;

  @override
  int nextInt(int max) {
    if (_used < draws.length) return draws[_used++] % max;
    return _fallback.nextInt(max);
  }

  @override
  double nextDouble() => _fallback.nextDouble();
  @override
  bool nextBool() => _fallback.nextBool();
}

void main() {
  group('list hygiene', () {
    test('lists are curated: sizeable, unique, ascii, no prefixes', () {
      for (final list in [shortcodeAdjectives, shortcodeNouns]) {
        expect(list.length, greaterThanOrEqualTo(150));
        expect(list.toSet().length, list.length,
            reason: 'duplicates inside the list');
        for (final word in list) {
          expect(word, matches(RegExp(r'^[a-z]{4,}$')),
              reason: 'not a plain lowercase word: "$word"');
        }
      }
      expect(shortcodeAdjectives.toSet().intersection(shortcodeNouns.toSet()),
          isEmpty,
          reason: 'a word appears in both lists');
      final all = [...shortcodeAdjectives, ...shortcodeNouns];
      for (final a in all) {
        for (final b in all) {
          if (a != b) {
            expect(b.startsWith(a), isFalse,
                reason: '"$a" is a prefix of "$b" — ambiguous pairs');
          }
        }
      }
    });

    test('draws are well-formed adjective-noun pairs', () {
      final random = Random(20260101);
      for (var i = 0; i < 500; i++) {
        final name = generateShortcode(random);
        expect(name, matches(RegExp(r'^[a-z]+-[a-z]+$')));
        final parts = name.split('-');
        expect(shortcodeAdjectives, contains(parts[0]));
        expect(shortcodeNouns, contains(parts[1]));
      }
    });

    test('mentions parse against shortcodes, hyphen included', () {
      final name = generateShortcode(Random(5));
      expect(parseMentions('hey @$name look'), [name]);
      expect(isBareShortcode(name), isTrue);
      expect(isBareShortcode('$name-2'), isFalse);
    });
  });

  group('collision avoidance', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tina_shortcode'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {}
    });

    test('a name held by an active member is redrawn', () {
      final store = SqliteChannelStore.open('${dir.path}/c.db');
      addTearDown(store.close);
      final taken = generateShortcode(ScriptedRandom([3, 7]));
      store.setMember('#lobby', taken,
          status: 'working', announce: false);
      final settled =
          settleAgentName(store, ScriptedRandom([3, 7, 4, 9]));
      expect(settled, isNot(taken));
      expect(isBareShortcode(settled), isTrue);
    });

    test('a departed member does not block their name', () {
      final store = SqliteChannelStore.open('${dir.path}/c.db');
      addTearDown(store.close);
      final taken = generateShortcode(ScriptedRandom([3, 7]));
      store.setMember('#lobby', taken, status: 'left', announce: false);
      final settled =
          settleAgentName(store, ScriptedRandom([3, 7]));
      expect(settled, taken);
    });

    test('exhausted retries fall back to a numeric suffix', () {
      final store = SqliteChannelStore.open('${dir.path}/c.db');
      addTearDown(store.close);
      // Every scripted draw yields the same pair: 8 retries all
      // collide, so the suffix path must engage.
      final drawn = generateShortcode(ScriptedRandom(List.filled(2, 3)));
      store.setMember('#lobby', drawn, status: 'working', announce: false);
      final settled = settleAgentName(store, ScriptedRandom(List.filled(64, 3)));
      expect(settled, startsWith('$drawn-'));
      expect(settled, isNot(drawn));
    });

    test('two store-backed sessions settle on distinct names', () {
      final db = '${dir.path}/pair.db';
      final first = SqliteChannelStore.open(db);
      final second = SqliteChannelStore.open(db);
      addTearDown(first.close);
      addTearDown(second.close);

      final nameA = settleAgentName(first, Random(1));
      // Session A joins for real; session B settles afterwards through
      // its own connection and must not land on A's name.
      first.setMember('#lobby', nameA, status: 'working', announce: false);
      final nameB = settleAgentName(second, Random(1));
      expect(nameB, isNot(nameA));

      // Registering both keeps them distinct for a third settle.
      second.setMember('#lobby', nameB, status: 'working', announce: false);
      final nameC = settleAgentName(first, Random(2));
      expect(nameC, isNot(nameA));
      expect(nameC, isNot(nameB));
    });
  });

  group('environment override', () {
    test('TINA_AGENT_NAME wins verbatim', () {
      expect(agentNameFromEnvironment({'TINA_AGENT_NAME': 'checkout-7'}),
          'checkout-7');
      expect(agentNameFromEnvironment({'TINA_AGENT_NAME': '  spaced  '}),
          'spaced');
    });

    test('absent or empty means generate', () {
      expect(agentNameFromEnvironment({}), isNull);
      expect(agentNameFromEnvironment({'TINA_AGENT_NAME': '   '}), isNull);
    });
  });
}
