// The capability envelope: one parse of a command produces every fact the
// permission checks consume. Pure — the same request and tables produce the
// same envelope — and it grants nothing; scopes and sandbox feasibility are
// decided elsewhere against these facts.
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

const searchPath = '/usr/bin:/bin';

ProcessRequest req(String command, List<String> arguments,
        [String? cwd]) =>
    (
      command: command,
      arguments: arguments,
      workingDirectory: cwd,
      environment: null,
      stdin: null,
      timeout: null,
    );

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('tina_envelope_');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('a certified single reader reports its read and provenance', () {
    final target = File('${root.path}/notes.txt')..writeAsStringSync('x\n');
    final envelope = CapabilityEnvelope.parse(req('cat', [target.path]),
        searchPath: searchPath);
    expect(envelope.certifiedReadOnly, isTrue);
    // /bin may symlink to /usr/bin; the envelope resolves through PATH.
    expect(path.basename(envelope.reader!), 'cat');
    expect(path.isAbsolute(envelope.reader!), isTrue);
    expect(envelope.reads, [target.path]);
    expect(envelope.writes, isEmpty);
    expect(envelope.destructive, isFalse);
    // The provenance names how the executable was resolved; either form of
    // resolution is a pinned absolute path (this container links /bin into
    // /usr/bin), never a bare name.
    expect(envelope.executions.first.executable, contains('cat'));
    expect(envelope.executions.first.provenance,
        anyOf(CapabilityProvenance.searchPath, CapabilityProvenance.absolute));
  });

  test('a certified pipeline pins every component and stays read-only', () {
    final source = File('${root.path}/payload')..writeAsStringSync('data');
    final envelope = CapabilityEnvelope.parse(
        req('/bin/sh', [
          '-c',
          'grep needle ${source.path} | head -5'
        ]),
        searchPath: searchPath);
    expect(envelope.certifiedReadOnly, isTrue);
    expect(envelope.shellReader, isNotNull,
        reason: 'the pipeline pinned a certified reader script');
    expect(envelope.reads, contains(source.path));
    expect(envelope.writes, isEmpty);
    expect(envelope.certifiedReadOnly, isTrue);
  });

  test('unknown commands are not certified and carry named provenance', () {
    final envelope =
        CapabilityEnvelope.parse(req('definitely-not-a-tool', ['x']),
            searchPath: searchPath);
    expect(envelope.certifiedReadOnly, isFalse);
    expect(envelope.verifiedAccesses, isEmpty);
    expect(envelope.completeVerifiedAccesses, isFalse);
    expect(envelope.executions.single.provenance,
        CapabilityProvenance.named,
        reason: 'an unresolved word never claims a resolved path');
  });

  test('control-declared directories and network ride the envelope', () {
    final envelope = CapabilityEnvelope.parse(req('echo', ['hi']),
        control: ProcessControl(
            networkRequested: true,
            readDirectories: ['/etc'],
            writeDirectories: ['/tmp/out']),
        searchPath: searchPath);
    expect(envelope.network, isTrue);
    expect(envelope.declaredReads, ['/etc']);
    expect(envelope.declaredWrites, ['/tmp/out']);
    expect(envelope.reads, contains('/etc'));
    expect(envelope.writes, contains('/tmp/out'));
    final quiet = CapabilityEnvelope.parse(req('echo', ['hi']),
        control: const ProcessControl(), searchPath: searchPath);
    expect(quiet.network, isFalse);
    expect(quiet.declaredReads, isEmpty);
  });

  test('the destructive table flags irreversible utilities and force-pushes',
      () {
    expect(
        CapabilityEnvelope.parse(req('rm', ['-rf', root.path]),
                searchPath: searchPath)
            .destructiveBecause,
        contains('rm'));
    expect(
        CapabilityEnvelope.parse(
                req('git', ['push', '--force', 'origin', 'main']),
                searchPath: searchPath)
            .destructiveBecause,
        contains('force'));
    expect(
        CapabilityEnvelope.parse(
                req('dd', ['if=rootfs.img', 'of=/dev/sda']),
                searchPath: searchPath)
            .destructiveBecause,
        contains('raw device'));
    expect(
        CapabilityEnvelope.parse(req('dd', ['if=a', 'of=b']),
                searchPath: searchPath)
            .destructive,
        isFalse,
        reason: 'dd to a regular file is not the device case');
  });

  test('a certified reader is never destructive; plain commands are not',
      () {
    final target = File('${root.path}/file')..writeAsStringSync('x');
    expect(
        CapabilityEnvelope.parse(req('cat', [target.path]),
                searchPath: searchPath)
            .destructive,
        isFalse);
    expect(
        CapabilityEnvelope.parse(req('ls', [root.path]),
                searchPath: searchPath)
            .destructive,
        isFalse);
    expect(
        CapabilityEnvelope.parse(req('truncate', ['-s', '0', target.path]),
                searchPath: searchPath)
            .destructiveBecause,
        isNotNull);
  });

  test('parsing is pure: the same request yields the same facts', () {
    final target = File('${root.path}/a.txt')..writeAsStringSync('a');
    final request = req('grep', ['needle', target.path]);
    final first =
        CapabilityEnvelope.parse(request, searchPath: searchPath);
    final second =
        CapabilityEnvelope.parse(request, searchPath: searchPath);
    expect(first.reads, second.reads);
    expect(first.reader, second.reader);
    expect(first.certifiedReadOnly, second.certifiedReadOnly);
    expect(first.destructiveBecause, second.destructiveBecause);
  });
}
