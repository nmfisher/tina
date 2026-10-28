import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  const homes = '/Users/nickfisher/.tina/sandbox-homes';
  const home = '$homes/session-22055-RZL4TR';

  group('isSessionScratchPath', () {
    test('sandbox-home generation paths are scratch', () {
      expect(
          isSessionScratchPath('$home/plans/deploy.md',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isTrue);
      expect(
          isSessionScratchPath(home,
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isTrue);
    });

    test('the sandbox TMPDIR is scratch wherever it sits', () {
      expect(
          isSessionScratchPath('$home/tmp/build-cache.bin',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isTrue);
    });

    test('workspace, host-home and unrelated tmp paths are not', () {
      expect(
          isSessionScratchPath('/Volumes/T7/projects/tina/.plans/x.md',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isFalse);
      expect(
          isSessionScratchPath('/Users/nickfisher/.zshrc',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isFalse);
      expect(
          isSessionScratchPath('/tmp/unrelated',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isFalse);
    });

    test('the state root itself and non-session siblings are not scratch',
        () {
      // The sandbox-homes directory is not itself a generation.
      expect(
          isSessionScratchPath(homes,
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isFalse);
      // e.g. a stray file dropped next to the generations.
      expect(
          isSessionScratchPath('$homes/README',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isFalse);
    });

    test('similar prefixes do not match', () {
      expect(
          isSessionScratchPath('$homes-other/session-1-abc/f',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isFalse);
    });
  });

  group('scratchPathNotice', () {
    test('returns the notice for scratch, null otherwise', () {
      expect(
          scratchPathNotice('$home/anything.md',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          scratchNotice);
      expect(
          scratchPathNotice('/workspace/anything.md',
              sandboxHomesRoot: homes, tmpdir: '$home/tmp'),
          isNull);
    });

    test('the notice names durable alternatives', () {
      expect(scratchNotice, contains('deleted when the session ends'));
      expect(scratchNotice, contains('.plans/'));
    });
  });
}
