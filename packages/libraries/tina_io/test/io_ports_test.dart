import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_io/tina_io.dart';

void main() {
  test('IoFileSystemPort round-trips text and reports modification time',
      () async {
    final dir = await Directory.systemTemp.createTemp('tina_io_fs_');
    addTearDown(() => dir.deleteSync(recursive: true));
    const fs = IoFileSystemPort();
    final path = '${dir.path}/models.json';

    await fs.createDirectory('${dir.path}/nested/deep', recursive: true);
    await fs.writeText(path, '{"hello": 1}');
    expect(await fs.readText(path), '{"hello": 1}');
    expect(Directory('${dir.path}/nested/deep').existsSync(), isTrue);

    final stamp = await fs.lastModified(path);
    expect(
        stamp.isBefore(DateTime.now().add(const Duration(seconds: 1))),
        isTrue);
    expect(() => fs.readText('${dir.path}/missing'),
        throwsA(isA<FileSystemException>()));
  });

  test('IoEnvironmentPort reads the real environment and cwd', () {
    const env = IoEnvironmentPort();
    expect(env.env('PATH'), isNotNull); // present in every test environment
    expect(env.currentDirectory, isNotEmpty);
  });

  test('IoHttpEndpoint resolves gateway paths onto the base, not the origin',
      () async {
    // A POST against a loopback server proves path resolution and the
    // response surface without any network beyond localhost.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      expect(request.uri.path, '/api/anthropic/v1/messages');
      request.response.statusCode = 200;
      request.response.close();
    });
    final endpoint = IoHttpEndpoint(
        endpoint: 'http://127.0.0.1:${server.port}/api/anthropic');
    addTearDown(endpoint.close);
    final response = await endpoint.post('/v1/messages',
        headers: const {}, body: utf8JsonBody);
    expect(response.statusCode, 200);
  });
}

final utf8JsonBody = '{}'.codeUnits;
