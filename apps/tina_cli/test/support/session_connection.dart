import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

SessionConnection testConnection({
  Host? host,
  SessionRole role = SessionRole.controller,
}) {
  final owner =
      host ??
      Host.start(
        HostConfig(
          workingDirectory: '.',
          providerFactory: (_) => ScriptedProvider([]),
        ),
      );
  if (host == null) addTearDown(owner.shutdown);
  final connection = owner.connect(role: role);
  addTearDown(connection.close);
  return connection;
}
