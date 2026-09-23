import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('isReadOnlyShellCommand — allow path', () {
    for (final command in [
      'cat notes.md',
      'grep -rn TODO src | head -20',
      'ls -la packages',
      'head -5 a.txt && tail -3 b.txt',
      'find . -name "*.dart"',
      'wc -l lib/*.dart',
      "grep 'a b' src/main.dart",
      'sort -n -u data.txt',
      'find . -name x -o -name y',
      'diff -u old.txt new.txt',
      '', // no-op: nothing runs
    ]) {
      test('allows: ${command.isEmpty ? '<empty no-op>' : command}', () {
        expect(isReadOnlyShellCommand(command), isTrue);
      });
    }
  });

  group('isReadOnlyShellCommand — deny-direction misses', () {
    for (final command in [
      'rm -rf /',
      'cat a > b',
      'echo x >> log.txt',
      'cat a < b', // input redirection also disqualifies (conservative)
      r'grep foo $(cat secrets)',
      'grep foo `cat secrets`',
      r'echo $HOME', // expansions hide options (`grep --pre=…`)
      'sed -n p f', // sed excluded: `-i` and `s///w` not modeled
      r"awk '{print $1}' f", // awk can system()
      'git status', // has its own fenced tool; classifier otherwise
      'python3 -c "print(1)"',
      './run.sh',
      '/bin/cat x',
      'cat a; rm b',
      'cat a | sh',
      'find . -delete',
      'find . -exec rm {} ;',
      'find . -name x -execdir echo {} ;',
      'sort -o out.txt in.txt',
      'uniq -o out.txt in.txt',
      'grep --pre="touch pwned" .',
      "date -s '2020-01-01'",
      'file -C magic.mgc',
      'env rm x',
      'timeout 5 cat x',
      'xargs rm',
      'tee log.txt',
      'tar -xf archive.tar',
      'tar -tf archive.tar', // tar excluded in v1 — even listing classifies
      'cat a\\; rm b', // the escape splits mid-word; rm segment still checked
      'X=1 cat a', // assignments push to the classifier
      'less f', // interactive viewer with shell escapes
    ]) {
      test('denies: $command', () {
        expect(isReadOnlyShellCommand(command), isFalse);
      });
    }

    test('quote-stripped flag lookalikes still deny', () {
      // sh unquotes before argv: these ARE `sed -i` / `find -delete`.
      expect(isReadOnlyShellCommand("sed '-i' f"), isFalse);
      expect(isReadOnlyShellCommand(r'sed \-i f'), isFalse);
      expect(isReadOnlyShellCommand("find . '-delete'"), isFalse);
      expect(isReadOnlyShellCommand('find . \\-delete'), isFalse);
    });
  });

  group('isReadOnlyShellInput — input-level gates', () {
    test('allows a plain read command', () {
      expect(isReadOnlyShellInput(const {'command': 'cat x'}), isTrue);
    });

    test('a custom environment disqualifies the static path (PATH hijack)', () {
      expect(
          isReadOnlyShellInput(const {
            'command': 'cat x',
            'environment': {'PATH': '/tmp/evil'},
          }),
          isFalse);
    });

    test('a non-string command is not provable', () {
      expect(isReadOnlyShellInput(const {'command': 42}), isFalse);
      expect(isReadOnlyShellInput(const {}), isFalse);
    });

    test('cwd does not affect read-only-ness', () {
      expect(
          isReadOnlyShellInput(const {'command': 'cat x', 'cwd': '/tmp'}),
          isTrue);
    });
  });
}
