import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';

/// The human identity derivation: override first, OS username
/// sanitized into a mention-safe name, `user` as the floor. Pure
/// functions of the environment — stable within a session by
/// construction.
void main() {
  group('humanNameFromEnvironment', () {
    test('a nonempty TINA_HUMAN_NAME wins verbatim (trimmed)', () {
      expect(
          humanNameFromEnvironment({'TINA_HUMAN_NAME': ' the-operator '}),
          'the-operator');
    });

    test('absent or blank means derive', () {
      expect(humanNameFromEnvironment(const {}), isNull);
      expect(humanNameFromEnvironment({'TINA_HUMAN_NAME': '  '}), isNull);
    });
  });

  group('sanitizeHumanName', () {
    test('lowercases and keeps mention-safe characters', () {
      expect(sanitizeHumanName('Ada_Lovelace'), 'ada_lovelace');
      expect(sanitizeHumanName('k8s.bot-2'), 'k8s.bot-2');
    });

    test('collapses unsafe runs to hyphens and trims the edges', () {
      expect(sanitizeHumanName('  Max  P. Jr '), 'max-p.-jr');
      expect(sanitizeHumanName('/tmp/root/'), 'tmp-root');
    });

    test('non-ASCII collapses to separators, never into the name', () {
      expect(sanitizeHumanName('Ünïcode User'), 'n-code-user');
    });

    test('caps at 32 characters', () {
      expect(sanitizeHumanName('a' * 80).length, 32);
    });

    test('nothing survives: the historic default user', () {
      expect(sanitizeHumanName(''), 'user');
      expect(sanitizeHumanName('***'), 'user');
    });
  });

  group('defaultHumanName', () {
    test('the override beats the OS username', () {
      expect(
          defaultHumanName(
              {'TINA_HUMAN_NAME': 'the-operator', 'USER': 'root'}),
          'the-operator');
    });

    test('derives from USER, then LOGNAME, then USERNAME', () {
      expect(defaultHumanName({'USER': 'Ada'}), 'ada');
      expect(defaultHumanName({'LOGNAME': 'BoB'}), 'bob');
      expect(defaultHumanName({'USERNAME': 'Cid'}), 'cid');
    });

    test('no username at all: user, stable across calls', () {
      const environment = {'HOME': '/nowhere'};
      expect(defaultHumanName(environment), 'user');
      expect(defaultHumanName(environment), defaultHumanName(environment));
    });
  });
}
