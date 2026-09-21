import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../composition/typesafe.dart';

/// Headless built-ins use the same command contributions as interactive
/// commands. UI-only commands are not mounted in this frontend.
PluginRuntime headlessCommands(AppComposition app) {
  final runtime = PluginRuntime(
    name: 'headless-commands',
    parent: app.pluginScope,
    plugins: [
      PluginDescriptor(
        id: 'tina.headless-commands',
        factory: FnPluginFactory((context) {
          context.register(
            Command(
              names: ['/help'],
              summary: 'show this list',
              helpOrder: 1,
              handler: (call) async {
                call.write(CommandRegistry(context.scope).renderHelp());
                return const CmdHandled();
              },
            ),
            id: 'tina.command.help',
          );
          context.register(
            Command(
              names: ['/index'],
              argsHint: '[jev|extensions] [status|refresh|view]',
              summary: 'classify languages, frameworks and tooling',
              helpOrder: 8,
              handler: (call) async {
                final options = IndexOptions.parse(call.arguments);
                if (options.mode == 'view') {
                  final view = await readProjectIndex(
                    app,
                    cancelSignal: call.cancelSignal,
                    onProgress: (text) => call.write('$text\n'),
                  );
                  try {
                    call.write('${await view.readText()}\n');
                  } finally {
                    await view.close();
                  }
                  return const CmdHandled();
                }
                final report = await runConfiguredProjectClassification(
                  app,
                  method: options.method,
                  mode: options.mode,
                  cancelSignal: call.cancelSignal,
                  onProgress: (text) => call.write('$text\n'),
                );
                call.write(classificationReportText(report));
                return CmdHandled(
                  failed: report.cancelled || report.failures.isNotEmpty,
                );
              },
            ),
            id: 'tina.command.index',
          );
          return Object();
        }),
      ),
    ],
  );
  runtime.activateSync();
  return runtime;
}
