import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina/config.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';
import '../helpers/fake_provider.dart';
import '../helpers/memory_session_store.dart';

void main() {
  test('compositions own independent tools unless explicitly borrowed', () async {
    final temp = Directory.systemTemp.createTempSync('tina-app-scopes-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final first = Directory('${temp.path}/first')..createSync();
    final second = Directory('${temp.path}/second')..createSync();
    final environment = FakeEnvironment(env: {'HOME': '${temp.path}/home'});
    final config = Config.parse(const ['--no-sandbox'], env: const {});

    Future<AppComposition> build(
      String root, {
      ProjectToolScope? tools,
      PromptContext? context,
      bool? trusted,
    }) async {
      final app = await buildAppComposition(
        config: config,
        registry: ProviderRegistry(env: const {}),
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
        environment: environment,
        projectRoot: root,
        toolScope: tools,
        promptContext: context,
        loadProjectContext: trusted,
      );
      addTearDown(() async {
        await app.scheduler.dispose();
        await app.store.close();
        app.startupProviderOverride!.close();
      });
      return app;
    }

    File('${first.path}/AGENTS.md').writeAsStringSync('FIRST PROJECT');
    File('${second.path}/AGENTS.md').writeAsStringSync('SECOND PROJECT');
    final a = await build(first.path, trusted: false);
    final originalWrite = a.pipeline.tools.buildTools()['write'];
    final b = await build(second.path);
    final background = await build(
      first.path,
      tools: a.pipeline.tools,
      context: a.pipeline.promptContext,
    );
    expect(background.pipeline.promptContext, same(a.pipeline.promptContext));
    expect(
      resolveMainPrompt(background.pipeline),
      isNot(contains('FIRST PROJECT')),
    );
    expect(resolveMainPrompt(b.pipeline), contains('SECOND PROJECT'));
    expect(resolveMainPrompt(a.pipeline), contains('cwd: ${first.path}'));
    await expectLater(
      build(second.path, context: a.pipeline.promptContext),
      throwsArgumentError,
    );
    await expectLater(
      build(first.path, context: a.pipeline.promptContext, trusted: true),
      throwsArgumentError,
    );

    expect(a.pipeline, isNot(same(b.pipeline)));
    expect(a.pipeline.tools, isNot(same(b.pipeline.tools)));
    expect(a.pipeline.tools.buildTools()['write'], same(originalWrite));
    expect(background.pipeline.tools, same(a.pipeline.tools));
    expect(background.scheduler.pipeline.tools, same(a.pipeline.tools));
    expect(a.scheduler.pipeline.tools, same(a.pipeline.tools));
    expect(b.scheduler.pipeline.tools, same(b.pipeline.tools));

    // A caller cannot accidentally use a borrowed lock/tool set for a different
    // project. The mismatch fails before composition acquires resources.
    await expectLater(
      build(second.path, tools: a.pipeline.tools),
      throwsArgumentError,
    );
  });
}
