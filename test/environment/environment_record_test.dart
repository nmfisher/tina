import 'dart:io';

import 'package:tina/environment/environment_record.dart';
import 'package:test/test.dart';

void main() {
  group('EnvironmentRecord.parse', () {
    test('reads bullets per section and skips preamble prose', () {
      const md = '''
# Environment

Intro prose before any heading — ignored.

## Toolchain
- Dart 3.9
- just 1.40

## Setup
- just get

## Observed
- test baseline: 42 passed
some non-bullet prose line
''';
      final r = EnvironmentRecord.parse(md);
      expect(r.bullets('Toolchain'), ['Dart 3.9', 'just 1.40']);
      expect(r.bullets('Setup'), ['just get']);
      expect(r.bullets('Observed'), ['test baseline: 42 passed']);
      expect(r.bullets('Missing'), isEmpty);
    });

    test('accepts * bullets and skips empty ones', () {
      const md = '''
## Setup
* star bullet
-
- real
''';
      final r = EnvironmentRecord.parse(md);
      expect(r.bullets('Setup'), ['star bullet', 'real']);
    });

    test('an empty body parses to an empty record', () {
      final r = EnvironmentRecord.parse('');
      expect(r.bullets('Toolchain'), isEmpty);
    });
  });

  group('EnvironmentRecord.load / exists', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_envrecord_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('load returns null when the file is absent', () {
      expect(EnvironmentRecord.exists(tmp.path), isFalse);
      expect(EnvironmentRecord.load(tmp.path), isNull);
    });

    test('load parses an existing record from the repo root', () {
      File('${tmp.path}/ENVIRONMENT.md').writeAsStringSync('''
## Build
- dart build
''');
      expect(EnvironmentRecord.exists(tmp.path), isTrue);
      expect(EnvironmentRecord.load(tmp.path)!.bullets('Build'), ['dart build']);
    });
  });

  group('promptBlock', () {
    EnvironmentRecord record() => EnvironmentRecord.parse('''
## Toolchain
- Dart 3.9

## Setup
- just get

## Build
- dart analyze

## Test
- dart test

## Test baseline
- 42 passed, 0 failed @ abc1234

## Auth
- gh auth status
''');

    test('renders each known section as a compact line + status: current', () {
      final block = record().promptBlock(stale: false);
      expect(block, startsWith('<project-environment>'));
      expect(block, endsWith('</project-environment>'));
      expect(block, contains('toolchain: Dart 3.9'));
      expect(block, contains('setup: just get'));
      expect(block, contains('build: dart analyze'));
      expect(block, contains('test: dart test'));
      expect(block, contains('baseline: 42 passed, 0 failed @ abc1234 (record claims)'));
      expect(block, contains('auth: gh auth status'));
      expect(block, contains('status: current'));
    });

    test('renders status: STALE with the machine-rendered reason', () {
      final block =
          record().promptBlock(stale: true, staleReason: 'inputs changed');
      expect(block, contains('status: STALE — inputs changed'));
      expect(block, isNot(contains('status: current')));
    });

    test('caps the block at maxBytes and still closes the tag', () {
      final long = EnvironmentRecord.parse(
          '## Setup\n- ${'x' * 5000}\n');
      final block = long.promptBlock(stale: false, maxBytes: 200);
      expect(block.length, lessThan(300));
      expect(block, endsWith('</project-environment>'));
      expect(block, contains('truncated'));
    });

    test('an empty record renders an empty (omittable) block', () {
      expect(EnvironmentRecord.parse('').promptBlock(stale: false), isEmpty);
    });
  });
}
