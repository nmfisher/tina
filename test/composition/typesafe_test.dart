import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tina/composition/typesafe.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/tui/settings_panel.dart';
import 'package:tina_engine/judgments.dart';
import 'package:tina_app/tina_app.dart';

import '../helpers/overlay_fixtures.dart';

void main() {
  test(
    'one exploration tool reloads UI credentials between invocations',
    () async {
      final fixture = TempTinaDir();
      fixture.setUp('tina_explore_composition_');
      addTearDown(fixture.tearDown);
      final auth = <String?>[];
      final tool = createConfiguredExplorationTool(
        projectRoot: fixture.dir.path,
        env: const {},
        tinaDir: fixture.dir,
        evidenceSource: _EvidenceSource(),
        clientFactory: () => MockClient((request) async {
          auth.add(request.headers['Authorization']);
          final body = jsonDecode(request.body) as Map;
          final rubric = body['questions']['relevance']['criteria'] as List;
          return http.Response(
            jsonEncode({
              'model': body['model'],
              'usage': {},
              'answers': {
                'relevance': {
                  'type': 'score',
                  'score': 4,
                  'legend': {
                    for (var i = 0; i < rubric.length; i++) '$i': rubric[i],
                  },
                  'probabilities': {
                    for (var i = 0; i < rubric.length; i++)
                      '$i': i == 4 ? 1 : 0,
                  },
                  'confidence': 0.9,
                },
              },
            }),
            200,
          );
        }),
      );
      expect(
        (await tool.execute({'question': 'widget'})).content,
        contains('/settings'),
      );
      for (final key in ['first', 'second']) {
        writeUserConfigPatch(
          env: const {},
          tinaDir: fixture.dir,
          typeSafeApiKey: key,
        );
        final result = await tool.execute({'question': 'widget'});
        expect(result.isError, isFalse);
        expect(
          jsonDecode(result.content)['findings'][0]['path'],
          'lib/widget.dart',
        );
      }
      expect(auth, ['Bearer first', 'Bearer second']);
    },
  );

  final tmp = TempTinaDir();
  setUp(() => tmp.setUp('tina_typesafe_composition_'));
  tearDown(tmp.tearDown);

  test(
    'saved key wins over environment; absent key falls back to environment',
    () {
      final config = resolveTypeSafeConfig(
        const UserConfig(
          typeSafe: TypeSafeSettings(apiKey: 'saved', model: 'pinned'),
        ),
        {'TYPESAFE_API_KEY': 'env-key'},
      );
      expect(config!.apiKey, 'saved');
      expect(config.model, 'pinned');
      expect(
        resolveTypeSafeConfig(UserConfig.empty, {
          'TYPESAFE_API_KEY': 'env-key',
        })!.apiKey,
        'env-key',
      );
      expect(resolveTypeSafeConfig(UserConfig.empty, const {}), isNull);
      expect(
        createConfiguredTypeSafeService(env: const {}, tinaDir: tmp.dir),
        isNull,
      );
    },
  );

  test(
    'saved UI key reaches HTTP and next construction reads replacement',
    () async {
      var calls = 0;
      final observed = <String?>[];
      final q = NoulQuestion('ready', instructions: 'Ready?');
      for (final key in ['first-key', 'replacement-key']) {
        final callsBeforeConstruction = calls;
        writeUserConfigPatch(
          env: const {},
          tinaDir: tmp.dir,
          typeSafeApiKey: key,
        );
        final service = createConfiguredTypeSafeService(
          env: const {},
          tinaDir: tmp.dir,
          clientFactory: () => MockClient((request) async {
            calls++;
            observed.add(request.headers['Authorization']);
            expect(jsonDecode(request.body)['model'], 'jev-latest');
            return http.Response(
              jsonEncode({
                'model': 'jev-latest',
                'usage': {},
                'answers': {
                  'ready': {'type': 'noul', 'noul': 0.9},
                },
              }),
              200,
            );
          }),
        );
        expect(
          calls,
          callsBeforeConstruction,
        ); // constructing never sends an auth probe
        expect(service, isNotNull);
        try {
          expect(
            (await service!.evaluate(
              JudgmentRequest(state: 'state', questions: [q]),
            )).answer(q).noul,
            0.9,
          );
        } finally {
          service?.close();
        }
      }
      expect(observed, ['Bearer first-key', 'Bearer replacement-key']);
      writeUserConfigPatch(env: const {}, tinaDir: tmp.dir, typeSafeApiKey: '');
      expect(
        createConfiguredTypeSafeService(env: const {}, tinaDir: tmp.dir),
        isNull,
      );
    },
  );
}

class _EvidenceSource implements ProjectEvidenceSource {
  @override
  Future<EvidenceScan> collect(
    String question,
    JudgmentCancellation cancellation,
    void Function(String) progress,
  ) async => EvidenceScan(
    [const ProjectEvidence('lib/widget.dart', 10, 'class Widget {}', 1)],
    1,
    [],
  );
}
