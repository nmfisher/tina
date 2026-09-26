import 'package:tina/config.dart';
import 'package:test/test.dart';

import '../helpers/test_registry.dart';

void main() {
  Config parse(List<String> args) =>
      Config.parse(args, env: const {}, registry: testRegistry(const {}));

  group('goal mode parsing', () {
    test('--goal seeds the goal text and defaults the cap', () {
      final cfg = parse(['--goal', 'make the tests pass']);
      expect(cfg.goal, 'make the tests pass');
      expect(cfg.maxGoalTurns, 25);
      expect(cfg.goalMode, isTrue);
      expect(cfg.nonInteractive, isTrue);
    });

    test('--goal implies non-interactive without claiming --prompt', () {
      final cfg = parse(['--goal', 'ship it']);
      expect(cfg.prompt, isNull);
    });

    test('--max-goal-turns overrides the cap', () {
      final cfg = parse(['--goal', 'g', '--max-goal-turns', '7']);
      expect(cfg.maxGoalTurns, 7);
    });

    test('--max-goal-turns 0 means unlimited', () {
      final cfg = parse(['--goal', 'g', '--max-goal-turns', '0']);
      expect(cfg.maxGoalTurns, 0);
    });

    test('a whitespace-only --goal is rejected outright', () {
      expect(
        () => parse(['--goal', '   ']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--goal needs a non-empty goal text'),
          ),
        ),
      );
    });

    test('--goal and --prompt are mutually exclusive', () {
      expect(
        () => parse(['--goal', 'a', '--prompt', 'b']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--goal and --prompt are mutually exclusive'),
          ),
        ),
      );
    });

    test('--goal and --workflow are mutually exclusive', () {
      expect(
        () => parse(['--goal', 'a', '--workflow', 'x']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--goal and --workflow are mutually exclusive'),
          ),
        ),
      );
    });

    test('--goal with the bare --resume picker is rejected', () {
      expect(
        () => parse(['--goal', 'a', '--resume']),
        throwsA(isA<FormatException>()),
      );
    });

    test('--max-goal-turns without --goal is rejected', () {
      expect(
        () => parse(['--max-goal-turns', '5']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--max-goal-turns only means something with --goal'),
          ),
        ),
      );
    });

    test('--max-goal-turns rejects negatives and non-numbers', () {
      expect(
        () => parse(['--goal', 'g', '--max-goal-turns', '-1']),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parse(['--goal', 'g', '--max-goal-turns', 'many']),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
