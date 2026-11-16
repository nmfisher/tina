import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';

void main() {
  group('parseMentions', () {
    test('extracts @names', () {
      expect(parseMentions('hey @tina-main look'), ['tina-main']);
    });

    test('several mentions keep first-appearance order, deduplicated', () {
      expect(parseMentions('@a and @b and @a'), ['a', 'b']);
    });

    test('name characters include dots, dashes and digits', () {
      expect(parseMentions('ping @perm-boxes.agent_2'), ['perm-boxes.agent_2']);
    });

    test('an interior at-sign does not mention', () {
      expect(parseMentions('user@example.com'), isEmpty);
    });

    test('start-of-text mentions count', () {
      expect(parseMentions('@lead starting'), ['lead']);
    });

    test('trailing punctuation is not part of the name', () {
      expect(parseMentions('hey @tina-main, status?'), ['tina-main']);
    });

    test('bare @ mentions nobody', () {
      expect(parseMentions('just an @ sign'), isEmpty);
    });

    test('case is preserved', () {
      expect(parseMentions('hi @Tina-Main'), ['Tina-Main']);
    });
  });

  group('normalizeChannelName', () {
    test('adds the leading # and lowercases', () {
      expect(normalizeChannelName('Lobby'), '#lobby');
      expect(normalizeChannelName('#Lobby'), '#lobby');
    });

    test('trims surrounding whitespace', () {
      expect(normalizeChannelName('  #lobby '), '#lobby');
    });

    test('rejects empty and oversized names', () {
      expect(() => normalizeChannelName('   '), throwsFormatException);
      expect(() => normalizeChannelName('#${'x' * 65}'), throwsFormatException);
    });

    test('rejects embedded whitespace', () {
      expect(() => normalizeChannelName('two words'), throwsFormatException);
    });
  });

  group('ChannelMessageType', () {
    test('name round-trips', () {
      for (final type in ChannelMessageType.values) {
        expect(ChannelMessageType.parse(type.name), type);
      }
    });

    test('unknown names are format errors', () {
      expect(() => ChannelMessageType.parse('shout'), throwsFormatException);
    });
  });
}
