import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tina/composition/typesafe.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/tui/settings_panel.dart';
import 'package:tina_app/tina_app.dart';

import '../helpers/overlay_fixtures.dart';

void main() {
  test(
    'configured tools reuse disk cache across frontend recreation and honor refresh',
    () async {
      final fixture = TempTinaDir();
      fixture.setUp('tina_cache_composition_');
      addTearDown(fixture.tearDown);
      var calls = 0;
      ExploreProjectTool build() => createConfiguredExplorationTool(
        projectRoot: fixture.dir.path,
        env: const {'TYPESAFE_API_KEY': 'key'},
        tinaDir: fixture.dir,
        evidenceSource: _EvidenceSource(),
        clientFactory: () => MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body) as Map;
          return http.Response(
            jsonEncode({
              'model': body['model'],
              'usage': {},
              'answers': {
                for (final id in (body['questions'] as Map).keys)
                  id: {'type': 'noul', 'noul': 0.9},
              },
            }),
            200,
          );
        }),
      );
      await build().execute({'question': 'widget', 'mode': 'verify'});
      expect(calls, 2);
      final repeated = jsonDecode(
        (await build().execute({
          'question': 'widget',
          'mode': 'verify',
        })).content,
      );
      expect(repeated['cache']['answer_hit'], isTrue);
      expect(repeated['usage']['charged_tokens'], 0);
      expect(calls, 2);
      await build().execute({
        'question': 'widget',
        'mode': 'verify',
        'refresh': true,
      });
      expect(calls, 4);
    },
  );

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
          if (body['state']['phase'] == 'file_ranking') {
            expect(body['state'].containsKey('content'), isFalse);
          } else {
            expect(body['questions']['matches']['type'], 'noul');
            expect(body['state']['content'], 'class Widget {}');
          }
          return http.Response(
            jsonEncode({
              'model': body['model'],
              'usage': {},
              'answers': {
                for (final id in (body['questions'] as Map).keys)
                  id: {'type': 'noul', 'noul': 0.9},
              },
            }),
            200,
          );
        }),
      );
      expect(
        (await tool.execute({
          'question': 'widget',
          'mode': 'verify',
          'refresh': true,
        })).content,
        contains('/settings'),
      );
      for (final key in ['first', 'second']) {
        writeUserConfigPatch(
          env: const {},
          tinaDir: fixture.dir,
          typeSafeApiKey: key,
        );
        final result = await tool.execute({
          'question': 'widget',
          'mode': 'verify',
          'refresh': true,
        });
        expect(result.isError, isFalse);
        expect(
          jsonDecode(result.content)['files'][0]['path'],
          'lib/widget.dart',
        );
      }
      expect(auth, [
        ...List.filled(2, 'Bearer first'),
        ...List.filled(2, 'Bearer second'),
      ]);
      writeUserConfig(
        const UserConfig(
          typeSafe: TypeSafeSettings(
            apiKey: 'second',
            explorationTokenBudget: 1,
          ),
        ),
        env: const {},
        tinaDir: fixture.dir,
      );
      final limited = await tool.execute({
        'question': 'widget',
        'mode': 'verify',
        'refresh': true,
      });
      expect(
        jsonDecode(limited.content)['files'][0]['regions'][0]['failure'],
        'budgetExceeded',
      );
      expect(
        auth,
        hasLength(5),
      ); // Only the manifest was sent after the new budget.
      writeUserConfig(
        const UserConfig(
          typeSafe: TypeSafeSettings(
            apiKey: 'second',
            explorationSelectionThreshold: 1,
          ),
        ),
        env: const {},
        tinaDir: fixture.dir,
      );
      final pruned = jsonDecode(
        (await tool.execute({
          'question': 'widget',
          'mode': 'verify',
          'refresh': true,
        })).content,
      );
      expect(pruned['files'][0]['regions'][0]['matches_probability'], 0.9);
      expect(
        auth,
        hasLength(7),
      ); // Verification can still examine low-ranked files.
      writeUserConfig(
        const UserConfig(
          typeSafe: TypeSafeSettings(
            apiKey: 'second',
            explorationMetadataTokenBudget: 1,
          ),
        ),
        env: const {},
        tinaDir: fixture.dir,
      );
      final noMetadata = jsonDecode(
        (await tool.execute({
          'question': 'widget',
          'mode': 'verify',
          'refresh': true,
        })).content,
      );
      expect(noMetadata['ranking']['failures'][0]['failure'], 'budgetExceeded');
      expect(auth, hasLength(7)); // Metadata budget reload blocked all HTTP.
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
  Future<ProjectTree> enumerate(
    JudgmentCancellation c,
    void Function(String) progress,
  ) async => ProjectTree(['lib/widget.dart'], []);
  @override
  Future<EvidenceScan> read(
    List<String> paths,
    JudgmentCancellation cancellation,
    void Function(String) progress, {
    int? maxBytes,
  }) async => EvidenceScan(
    [const ProjectEvidence('lib/widget.dart', 'class Widget {}')],
    1,
    [],
  );
}
