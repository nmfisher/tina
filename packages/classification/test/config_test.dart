import 'dart:io';
import 'package:classification/config.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File config;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('classification-config-');
    config = File('${directory.path}/config');
  });
  tearDown(() => directory.deleteSync(recursive: true));
  test(
    'stored Typesafe credentials win; model and endpoint remain separate from chat',
    () {
      config.writeAsStringSync(
        '[default]\nmodel="chat-model"\n[typesafe]\napi_key="stored-key"\nmodel="jev-pinned"\nendpoint="http://127.0.0.1:8080/judge"\n',
      );
      final value = readClassificationConfig(
        config.path,
        environment: {'TYPESAFE_API_KEY': 'env-key'},
      )!;
      expect(value.apiKey, 'stored-key');
      expect(value.model, 'jev-pinned');
      expect(value.endpoint.path, '/judge');
    },
  );
  test(
    'missing or cleared key uses the environment; explicit variable resolves',
    () {
      expect(readClassificationConfig(config.path, environment: {}), isNull);
      expect(
        readClassificationConfig(
          config.path,
          environment: {'TYPESAFE_API_KEY': 'env-key'},
        )!.apiKey,
        'env-key',
      );
      config.writeAsStringSync('[typesafe]\napi_key=""\n');
      expect(
        readClassificationConfig(
          config.path,
          environment: {'TYPESAFE_API_KEY': 'env-key'},
        )!.apiKey,
        'env-key',
      );
      config.writeAsStringSync(
        r'[typesafe]'
        '\n'
        r'api_key="${CLASSIFICATION_KEY}"',
      );
      expect(
        readClassificationConfig(
          config.path,
          environment: {'CLASSIFICATION_KEY': 'variable-key'},
        )!.apiKey,
        'variable-key',
      );
      expect(readClassificationConfig(config.path, environment: {}), isNull);
    },
  );
}
