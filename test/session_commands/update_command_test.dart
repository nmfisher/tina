import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tina/conversation.dart';
import 'package:tina/self_update/release_checker.dart';
import 'package:tina/session_commands/command_context.dart';
import 'package:tina/session_commands/session_command_handlers.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// `/update` handler tests. The checker is injected with a fake HTTP client
/// serving a canned GitHub release payload — no network, no install (the
/// install path itself is covered in test/self_update/updater_test.dart).
void main() {
  late FakeHostInterface host;
  late Conversation conv;

  setUp(() {
    host = FakeHostInterface();
    conv = Conversation(
      id: 'c1',
      label: 'test',
      agent: Agent(
        provider: FakeProvider.always(model: 'm'),
        tools: ToolRegistry(const []),
        sink: host,
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        system: '',
      ),
      provider: FakeProvider.always(model: 'm'),
      host: host,
      policy: PermissionPolicy(),
    );
  });

  /// A handler whose release checker serves [tag] from a fake GitHub API.
  SessionCommandHandlers handlers({String tag = 'v99.0.0', bool? confirm}) {
    return SessionCommandHandlers(
        _Ctx(conv,
            confirm: confirm == null ? null : (_) async => confirm),
        releaseCheckerFactory: (env) => ReleaseChecker(
              env: env,
              client: _FakeGithubClient(tag),
            ));
  }

  test('reports up to date when the latest tag is not newer', () async {
    final h = handlers(tag: 'v0.0.1');
    await h.dispatch('/update');
    expect(host.messages.any((m) => m.contains('up to date')), isTrue);
    expect(host.messages.any((m) => m.contains('v0.0.1')), isTrue);
  });

  test('newer release + headless (no confirm) links the release', () async {
    final h = handlers(tag: 'v99.0.0'); // confirm is null → headless
    await h.dispatch('/update');
    expect(
        host.messages.any((m) => m.contains('v99.0.0 is available')), isTrue);
    expect(host.messages.any((m) => m.contains('headless run')), isTrue);
    expect(host.messages.any((m) => m.contains('https://github.com/')), isTrue);
  });

  test('declining the confirm installs nothing', () async {
    final h = handlers(tag: 'v99.0.0', confirm: false);
    await h.dispatch('/update');
    expect(host.messages.any((m) => m.contains('restart tina')), isFalse);
  });

  test('unreachable API is a warning, not an error', () async {
    final h = SessionCommandHandlers(
        _Ctx(conv, confirm: (_) async => true),
        releaseCheckerFactory: (env) => ReleaseChecker(
              env: env,
              client: _BrokenClient(),
            ));
    await h.dispatch('/update');
    expect(host.messages.any((m) => m.contains('could not reach GitHub')),
        isTrue);
  });

  test('/update is in allCommands (completion palette source of truth)',
      () {
    expect(SessionCommandHandlers.allCommands, contains('/update'));
  });
}

class _Ctx implements CommandContext {
  _Ctx(this.conversation, {this.confirm});

  final Conversation conversation;
  @override
  Conversation get active => conversation;
  @override
  final Future<bool> Function(String prompt)? confirm;

  @override
  Map<String, FutureOr<void> Function()> get commandHooks => const {};

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Serves a GitHub `/releases/latest` payload for [tag] on any request.
class _FakeGithubClient extends http.BaseClient {
  _FakeGithubClient(this.tag);
  final String tag;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonEncode({
      'tag_name': tag,
      'html_url': 'https://github.com/nmfisher/tina/releases/tag/$tag',
      'assets': [
        {
          'name': 'tina-$tag-example.tar.gz',
          'browser_download_url': 'https://example.com/tina-$tag.tar.gz',
        }
      ],
    });
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
  }
}

/// Every request fails — drives the "could not reach GitHub" path.
class _BrokenClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw const SocketException('no network in tests');
  }
}
