import 'dart:io';

import 'package:tina/project/project_trust.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('hasAgentsMdUpTree finds AGENTS.md in cwd or an ancestor', () async {
    final tmp = await Directory.systemTemp.createTemp('tina_trust_tree_');
    try {
      final sub = Directory(p.join(tmp.path, 'a', 'b'))
        ..createSync(recursive: true);
      expect(hasAgentsMdUpTree(sub.path), isFalse);
      File(p.join(tmp.path, 'AGENTS.md')).writeAsStringSync('# rules');
      expect(hasAgentsMdUpTree(sub.path), isTrue, reason: 'ancestor match');
      expect(hasAgentsMdUpTree(tmp.path), isTrue, reason: 'cwd match');
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('ProjectTrustStore round-trips and recovers from a corrupt file',
      () async {
    final tmp = await Directory.systemTemp.createTemp('tina_trust_store_');
    try {
      final store = ProjectTrustStore.forTinaDir(tmp);
      expect(store.isTrusted(tmp.path), isFalse);
      store.setTrusted(tmp.path, true);
      expect(store.isTrusted(tmp.path), isTrue);
      store.setTrusted(tmp.path, false);
      expect(store.isTrusted(tmp.path), isFalse);
      // A corrupt store file must not throw or block — it reads as empty.
      File(p.join(tmp.path, 'trusted_projects.json'))
          .writeAsStringSync('{not valid json');
      expect(store.isTrusted(tmp.path), isFalse);
    } finally {
      await tmp.delete(recursive: true);
    }
  });

  test('resolveProjectTrust: override wins; branches; ask persists', () async {
    // A project dir WITH an AGENTS.md (so the gate has something to withhold).
    final project =
        await Directory.systemTemp.createTemp('tina_trust_resolve_');
    final storeDir =
        await Directory.systemTemp.createTemp('tina_trust_storeb_');
    try {
      File(p.join(project.path, 'AGENTS.md')).writeAsStringSync('# inject me');
      final store = ProjectTrustStore.forTinaDir(storeDir);

      // Explicit override wins either way.
      expect(
          await resolveProjectTrust(
              cwd: project.path, store: store, hasUi: true, override: true),
          isTrue);
      expect(
          await resolveProjectTrust(
              cwd: project.path, store: store, hasUi: true, override: false),
          isFalse);

      // Headless + untrusted + AGENTS.md → skip (false), no ask.
      expect(
          await resolveProjectTrust(
              cwd: project.path, store: store, hasUi: false),
          isFalse);

      // defaultMode always / never short-circuit.
      expect(
          await resolveProjectTrust(
              cwd: project.path,
              store: store,
              hasUi: false,
              defaultMode: TrustDefault.always),
          isTrue);
      expect(
          await resolveProjectTrust(
              cwd: project.path,
              store: store,
              hasUi: true,
              defaultMode: TrustDefault.never),
          isFalse);

      // ask → yes persists, so a follow-up resolves without asking.
      var asked = 0;
      final decided = await resolveProjectTrust(
        cwd: project.path,
        store: store,
        hasUi: true,
        ask: (_) async {
          asked++;
          return true;
        },
      );
      expect(decided, isTrue);
      expect(asked, 1);
      expect(store.isTrusted(project.path), isTrue);

      final again = await resolveProjectTrust(
        cwd: project.path,
        store: store,
        hasUi: true,
        ask: (_) async => throw StateError('should not ask — already trusted'),
      );
      expect(again, isTrue);
      expect(asked, 1, reason: 'stored trust must short-circuit the ask');
    } finally {
      await project.delete(recursive: true);
      await storeDir.delete(recursive: true);
    }
  });
}
