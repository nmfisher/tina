import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tina_app/tina_app.dart';
import 'package:tina/self_update/release_checker.dart';
import 'package:tina/self_update/updater.dart';

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

  /// Ready with an in-memory prepared update: install() reports success
  /// without touching disk, discard() is a no-op — the swap mechanics are
  /// covered in test/self_update/updater_test.dart.
  Future<UpdatePrepareOutcome> _fakePrepare(
    ReleaseInfo release,
    void Function(String line) notice,
  ) async {
    return UpdatePrepareReady(_FakePrepared(release.tag));
  }

  /// A handler whose release checker serves [tag] from a fake GitHub API.
  /// [prepare] fakes the download/verify/extract stage (default: ready).
  ({SessionCommandHandlers handlers, _Ctx ctx}) handlers({
    String tag = 'v99.0.0',
    bool? confirm,
    Future<bool> Function(String prompt)? onConfirm,
    Future<UpdatePrepareOutcome> Function(
      ReleaseInfo release,
      void Function(String line) notice,
    )?
    prepare,
  }) {
    final ctx = _Ctx(
      conv,
      onConfirm: onConfirm ?? (confirm == null ? null : (_) async => confirm),
    );
    return (
      handlers: SessionCommandHandlers(
        ctx,
        releaseCheckerFactory: (env) =>
            ReleaseChecker(env: env, client: _FakeGithubClient(tag)),
        prepareUpdateOverride: prepare ?? _fakePrepare,
      ),
      ctx: ctx,
    );
  }

  test('reports up to date when the latest tag is not newer', () async {
    final (handlers: h, ctx: _) = handlers(tag: 'v0.0.1');
    await h.dispatch('/update');
    expect(host.messages.any((m) => m.contains('up to date')), isTrue);
    expect(host.messages.any((m) => m.contains('v0.0.1')), isTrue);
  });

  test('newer release + headless (no confirm) links the release', () async {
    final (handlers: h, ctx: _) = handlers(
      tag: 'v99.0.0',
    ); // confirm is null → headless
    await h.dispatch('/update');
    expect(
      host.messages.any((m) => m.contains('v99.0.0 is available')),
      isTrue,
    );
    expect(host.messages.any((m) => m.contains('headless run')), isTrue);
    expect(host.messages.any((m) => m.contains('https://github.com/')), isTrue);
  });

  test('declining the confirm installs nothing', () async {
    var discarded = false;
    final (handlers: h, ctx: _) = handlers(
      tag: 'v99.0.0',
      confirm: false,
      prepare: (release, notice) async => UpdatePrepareReady(
        _FakePrepared(release.tag, onDiscard: () => discarded = true),
      ),
    );
    await h.dispatch('/update');
    expect(host.messages.any((m) => m.contains('restart tina')), isFalse);
    expect(
      discarded,
      isTrue,
      reason: 'a declined confirm discards the download',
    );
  });

  test('the confirm happens after the download, not before', () async {
    var downloaded = false;
    var downloadedWhenPrompted = false;
    final (handlers: h, ctx: ctx) = handlers(
      tag: 'v99.0.0',
      onConfirm: (_) async {
        downloadedWhenPrompted = downloaded;
        return true;
      },
      prepare: (release, notice) async {
        downloaded = true;
        return UpdatePrepareReady(_FakePrepared(release.tag));
      },
    );
    await h.dispatch('/update');
    expect(downloaded, isTrue);
    expect(
      downloadedWhenPrompted,
      isTrue,
      reason: 'download runs before the y/n prompt appears',
    );
    expect(ctx.prompts.single, contains('downloaded and verified'));
    expect(ctx.prompts.single, contains('install it now?'));
    expect(host.messages.any((m) => m.contains('restart tina')), isTrue);
  });

  test('interactive run does not stop at the availability notice', () async {
    // Regression: the old flow asked y/n before any download; the new one
    // must reach the prepare stage (and the prompt) on its own.
    final (handlers: h, ctx: ctx) = handlers(tag: 'v99.0.0', confirm: false);
    await h.dispatch('/update');
    expect(ctx.prompts.single, contains('install it now?'));
  });

  test('unreachable API is a warning, not an error', () async {
    final h = SessionCommandHandlers(
      _Ctx(conv, onConfirm: (_) async => true),
      releaseCheckerFactory: (env) =>
          ReleaseChecker(env: env, client: _BrokenClient()),
    );
    await h.dispatch('/update');
    expect(
      host.messages.any((m) => m.contains('could not reach GitHub')),
      isTrue,
    );
  });

  test('/update is in allCommands (completion palette source of truth)', () {
    expect(SessionCommandHandlers.allCommands, contains('/update'));
  });
}

class _Ctx implements CommandContext {
  _Ctx(this.conversation, {Future<bool> Function(String prompt)? onConfirm})
    : _onConfirm = onConfirm;

  final Conversation conversation;
  final Future<bool> Function(String prompt)? _onConfirm;

  /// Every confirm prompt the handler showed, in order.
  final List<String> prompts = [];

  @override
  Conversation get active => conversation;

  @override
  Future<bool> Function(String prompt)? get confirm => _onConfirm == null
      ? null
      : (prompt) {
          prompts.add(prompt);
          return _onConfirm(prompt);
        };

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
        },
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

/// A [PreparedUpdate] that never touches disk: install reports success,
/// discard records the call. Exercises the handler's flow only.
class _FakePrepared implements PreparedUpdate {
  _FakePrepared(this.tag, {this.onDiscard});

  @override
  final String tag;

  final void Function()? onDiscard;

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #install) {
      return Future.value(UpdateResult.success);
    }
    if (i.memberName == #discard) {
      onDiscard?.call();
      return null;
    }
    return super.noSuchMethod(i);
  }
}
