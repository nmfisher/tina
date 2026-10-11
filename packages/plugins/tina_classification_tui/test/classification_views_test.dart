import 'dart:async';

import 'package:classification/judgments.dart';
import 'package:classification/plugin.dart';
import 'package:test/test.dart';
import 'package:tina_classification_tui/tina_classification_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

import 'support/console_fixture.dart';

final class _Output implements Terminal {
  @override
  void writeln([String? line]) {}
  @override
  Future<String> ask(String prompt) async => '';
}

final class _Presentation {
  _Presentation(ClassificationObservation observation) {
    home.setOuter(screen.chat.bounds);
    focus.register(home);
    focus.home = home;
    editor.focusManager = focus;
    view = ClassificationView(observation);
    attachment = ConsoleAttachment.attach(
      view,
      ConsoleContext(screen: screen, editor: editor),
    );
  }
  final io = Io();
  late final screen = Screen(
    io: io,
    ansi: AnsiCapable.yes,
    layout: ScreenLayout.fromSize(100, 24, split: false),
  );
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  final focus = FocusManager();
  late final home = PanelFrame(
    screen: screen,
    label: 'chat',
    conversationId: 'test',
    border: false,
  );
  late final ClassificationView view;
  late final ConsoleAttachment attachment;
  String get visible {
    final terminal = VirtualTerminal(width: 100, height: 24)
      ..feed(io.output.toString());
    return List.generate(24, terminal.rowText).join('\n');
  }

  void dispose() {
    attachment.dispose();
    home.dispose();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  }
}

final class _Pending implements JudgmentService {
  final requests = <JudgmentRequest>[];
  final results = <Completer<JudgmentResult>>[];
  JudgmentCancellation? cancellation;
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) {
    requests.add(request);
    this.cancellation = cancellation;
    final done = Completer<JudgmentResult>();
    results.add(done);
    return done.future;
  }

  void complete() {
    final request = requests.single;
    final question = request.questions.values.single as ChoiceQuestion;
    results.single.complete(
      JudgmentResult.fromJson({
        'model': 'fixture',
        'usage': {},
        'answers': {
          question.id: {
            'type': 'choice',
            'choice': 'projectQuestion',
            'confidence': .99,
            'probabilities': {
              for (final key in question.criteria.keys)
                key: key == 'projectQuestion' ? 1.0 : 0.0,
            },
          },
        },
      }, request: request),
    );
  }
}

void main() {
  for (final detachFirst in [true, false]) {
    test(
      'independent panels survive either detach (first: $detachFirst)',
      () async {
        final plugin = ClassificationPlugin(
          terminal: _Output(),
          open: () => null,
        );
        addTearDown(plugin.closeSession);
        final first = _Presentation(plugin.observation);
        final second = _Presentation(plugin.observation);
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        final root = plugin.trace.begin(
          inputId: 'one',
          title: 'First stage',
          request: {},
          questions: {
            'check': {'type': 'noul', 'instructions': 'A check'},
          },
        );
        plugin.trace.begin(inputId: 'one', title: 'Second stage', request: {});
        expect(first.visible, contains('First stage'));
        expect(second.visible, contains('First stage'));
        first.view.panel!.show(hierarchy: true);
        second.view.panel!.show();
        while (first.view.panel!.selected!.exchange.id != root.id ||
            first.view.panel!.selected!.kind !=
                ClassificationRowKind.classifier) {
          first.view.panel!.handleEvent(ArrowKey(ArrowDirection.up));
        }
        first.view.panel!.handleEvent(ArrowKey(ArrowDirection.right));
        first.view.panel!.handleEvent(ArrowKey(ArrowDirection.down));
        expect(first.view.panel!.hierarchy, isTrue);
        expect(first.view.panel!.details, isTrue);
        expect(second.view.panel!.hierarchy, isFalse);
        expect(second.view.panel!.details, isFalse);
        expect(second.view.panel!.selected!.exchange.id, isNot(root.id));
        expect(first.focus.focused, same(first.view.panel));
        expect(second.focus.focused, same(second.view.panel));
        final detached = detachFirst ? first : second;
        final survivor = detachFirst ? second : first;
        detached.attachment.dispose();
        detached.attachment.dispose();
        expect(detached.view.panel, isNull);
        expect(detached.focus.focused, same(detached.home));
        expect(survivor.view.panel!.hasFocus, isTrue);
        detached.io.output.clear();
        root.complete();
        root.recordOutcome(const ClassificationOutcome('shared outcome'));
        await pumpEventQueue();
        expect(survivor.visible, contains('shared outcome'));
        expect(detached.io.output.toString(), isEmpty);
        expect(
          detached.view.handleConsoleCommand('classification', ''),
          isNull,
        );
        final replacement = _Presentation(plugin.observation);
        addTearDown(replacement.dispose);
        expect(replacement.visible, contains('shared outcome'));
        expect(replacement.view.panel!.hierarchy, isFalse);
        expect(replacement.view.panel!.details, isFalse);
        expect(
          replacement.view.classification.trace,
          same(survivor.view.classification.trace),
        );
      },
    );
  }

  test('detaching both views preserves one in-flight classification', () async {
    final service = _Pending();
    var opened = 0, closed = 0;
    final plugin = ClassificationPlugin(
      terminal: _Output(),
      open: () {
        opened++;
        return ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () => closed++,
        );
      },
    );
    addTearDown(plugin.closeSession);
    final first = _Presentation(plugin.observation);
    final second = _Presentation(plugin.observation);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    plugin.onInput(
      TurnContext(
        CancelToken(),
        input: Input('explain this', id: 'one'),
        messages: [],
        promptSections: [],
        pinnedTools: [],
      ),
    );
    await pumpEventQueue();
    expect(service.requests, hasLength(1));
    expect(opened, 1);
    expect(first.visible, contains('[loading]'));
    expect(second.visible, contains('[loading]'));
    first.attachment.dispose();
    second.attachment.dispose();
    expect(closed, 0);
    expect(service.cancellation!.isCancelled, isFalse);
    service.complete();
    await pumpEventQueue();
    expect(plugin.status.phase, ClassificationPhase.ready);
    expect(service.requests, hasLength(1));
    expect(closed, 1);
    final replacement = _Presentation(plugin.observation);
    addTearDown(replacement.dispose);
    expect(replacement.visible, contains('Project question'));
    expect(plugin.trace.exchanges, hasLength(1));
  });
}
