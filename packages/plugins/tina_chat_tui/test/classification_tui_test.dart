import 'dart:async';
import 'package:classification/plugin.dart';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_plans/tina_plans.dart';
import 'console_test.dart' show Io;
import 'plans_tui_test.dart' show Panels;

class Output implements Terminal {
  @override
  Future<String> ask(String prompt) async => '';
  @override
  void writeln([String? line]) {}
}

void main() {
  late Io io;
  late Screen screen;
  late LineEditor editor;
  late ConsoleContext context;
  late ClassificationConsolePlugin plugin;
  late FocusManager focus;
  late PanelFrame home;
  late bool active;
  VirtualTerminal terminal() =>
      VirtualTerminal(width: screen.layout.width, height: screen.layout.height)
        ..feed(io.output.toString());
  String visible() {
    final vt = terminal();
    return List.generate(screen.layout.height, vt.rowText).join('\n');
  }

  ClassificationExchange request(
          {String inputId = 'input-1', int? parent, bool git = false}) =>
      plugin.trace.begin(
        inputId: inputId,
        title: git ? 'Git operations' : 'Intent',
        parentId: parent,
        request: {
          'model': 'fixture',
          'state': {
            'evidence': [
              {'meaning': 'latest input', 'text': 'push the branch'}
            ]
          },
          'questions': git
              ? {
                  'push': {'type': 'noul', 'instructions': 'Is this a push?'},
                  'checkout': {
                    'type': 'noul',
                    'instructions': 'Is this checkout?'
                  }
                }
              : {
                  'intent': {
                    'type': 'choice',
                    'instructions': 'What is the intent?',
                    'criteria': {
                      'projectQuestion': {
                        'label': 'project question',
                        'question': 'Is this a project question?'
                      },
                      'agentInstruction': {
                        'label': 'instruction',
                        'question': 'Is this an instruction?'
                      },
                      'other': 'Neither'
                    }
                  }
                }
        },
      );
  setUp(() {
    active = true;
    io = Io();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(100, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    focus = FocusManager();
    home = PanelFrame(
        screen: screen, label: 'chat', conversationId: 'test', border: false)
      ..setOuter(screen.chat.bounds);
    focus.register(home);
    focus.home = home;
    editor.focusManager = focus;
    context = ConsoleContext(screen: screen, editor: editor).forView(
        chat: screen.chat,
        isActive: () => active,
        activate: () {},
        panels: Panels());
    plugin = ClassificationConsolePlugin(terminal: Output(), open: () => null);
    plugin.attachConsole(context);
  });
  tearDown(() {
    plugin.closeSession();
    home.dispose();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });

  test(
      'shows request before reply, removes status label, and preserves history across reattachment',
      () async {
    final e = request();
    expect(visible(), contains('classification'));
    expect(visible(), contains('Input: push the branch'));
    expect(visible(), contains('Reply: waiting'));
    expect(visible(), isNot(contains('intent: classifying')));
    e.complete({
      'model': 'fixture',
      'answers': {
        'intent': {
          'type': 'choice',
          'choice': 'agentInstruction',
          'confidence': .99,
          'probabilities': {
            'agentInstruction': .99,
            'projectQuestion': .01,
            'other': 0.0
          }
        }
      },
      'usage': {}
    });
    expect(visible(), contains('agentInstruction 99.0%'));
    plugin.detachConsole();
    expect(plugin.panel, isNull);
    plugin.attachConsole(context);
    expect(visible(), contains('agentInstruction 99.0%'));
    plugin.panel!.show(hierarchy: true);
    final labels = classificationPanelRows(plugin.trace, hierarchy: true)
        .map((r) => r.label);
    expect(labels, contains('✓ instruction · 99.0%'));
  });

  test(
      'unconfigured classifier stays out of focus cycling until explicitly opened',
      () async {
    plugin.onInput(TurnContext(CancelToken(),
        input: Input('hello', id: 'hello'),
        messages: [],
        promptSections: [],
        pinnedTools: []));
    await pumpEventQueue();
    expect(plugin.status.phase, ClassificationPhase.unavailable);
    expect(plugin.panel!.canFocus, false);
    focus.engage();
    focus.moveHighlightCyclic(1);
    focus.commit();
    expect(focus.focused, same(home));
    await plugin.commands.single.handler('');
    expect(plugin.panel!.canFocus, true);
    expect(visible(), contains('unavailable: configure'));
  });

  test(
      'hierarchy includes every evaluated question, negative answers, choices and dependencies',
      () {
    final e = request();
    final git = request(parent: e.id, git: true);
    git.complete({
      'answers': {
        'push': {'type': 'noul', 'noul': .99},
        'checkout': {'type': 'noul', 'noul': .01}
      }
    });
    final rows = classificationPanelRows(plugin.trace, hierarchy: true);
    expect(rows.map((r) => r.label), contains('checkout · P(yes) 1.0%'));
    expect(rows.map((r) => r.label), contains('push · P(yes) 99.0%'));
    expect(
        rows.singleWhere((r) => r.exchange == git && r.question == null).depth,
        1);
    expect(rows.where((r) => r.choice != null), hasLength(3));
    plugin.panel!.show(hierarchy: true);
    expect(visible(), contains('classification · hierarchy'));
    plugin.panel!.handleEvent(CharInput('h'));
    expect(plugin.panel!.hierarchy, false);
  });

  test('a clipped body retains all 254 category choices in the hierarchy', () {
    final questions = {
      'intent': {
        'type': 'choice',
        'criteria': {
          for (var i = 0; i < 254; i++)
            'category$i': {
              'label': 'Category $i',
              'question': 'Does this concern category $i?'
            },
          'other': 'Other'
        }
      }
    };
    final e = plugin.trace.begin(
        inputId: 'large',
        title: 'Intent',
        request: {'padding': 'x' * 70000, 'questions': questions},
        questions: questions);
    e.recordAnswers({
      'intent': {
        'choice': 'category253',
        'confidence': .99,
        'probabilities': {'category253': .99}
      }
    });
    e.complete();
    expect(e.request, contains('[display truncated]'));
    final rows = classificationPanelRows(plugin.trace, hierarchy: true);
    expect(rows.where((r) => r.choice != null), hasLength(255));
    expect(rows.map((r) => r.label), contains('✓ Category 253 · 99.0%'));
  });

  test(
      'real editor browses details without submitting; Escape restores draft and cursor',
      () async {
    final prompt = editor.readLine('model > ');
    await pumpEventQueue();
    editor.inject(CharInput('keep my draft'));
    request();
    plugin.panel!.show();
    expect(terminal().cursorVisible, false);
    editor.refresh();
    expect(terminal().cursorVisible, false);
    editor.inject(ControlKey(ControlCode.enter));
    expect(plugin.panel!.details, true);
    expect(visible(), contains('Request'));
    final before = visible();
    editor.inject(ArrowKey(ArrowDirection.down));
    expect(visible(), isNot(before));
    editor.inject(ArrowKey(ArrowDirection.left));
    editor.inject(EscapeKey());
    expect(focus.focused, same(home));
    expect(terminal().cursorVisible, true);
    editor.inject(ControlKey(ControlCode.enter));
    expect(await prompt, 'keep my draft');
  });

  test('live updates yield to dialogs and an idle panel never redraws',
      () async {
    final e = request();
    final key = editor.readKey();
    final modal = OverlayRegion(screen, plugin.panel!.bounds)
      ..show(['APPROVAL QUESTION']);
    e.complete({
      'answers': {
        'intent': {'choice': 'projectQuestion', 'confidence': .95}
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(visible(), contains('APPROVAL QUESTION'));
    io.feed('\r');
    await key;
    modal.dispose();
    plugin.repaintConsole();
    expect(visible(), contains('projectQuestion 95.0%'));
    await pumpEventQueue();
    io.output.clear();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(io.output.toString(), isEmpty);
  });

  test(
      'shares sidebar with plan, fits a small terminal, switches views, and unloads focused',
      () async {
    final plans = PlansConsolePlugin();
    final loop = AgentLoop(provider: ScriptedProvider([]), plugins: [plans]);
    plans.mountOn(loop);
    plans.attachConsole(context);
    addTearDown(plans.closeSession);
    plans.store.update(
        loop, [const PlanEntryItem('current step', state: 'in_progress')]);
    request();
    await pumpEventQueue();
    plugin.repaintConsole();
    plans.repaintConsole();
    expect(plans.overlay!.bounds.bottom, lessThan(plugin.panel!.bounds.row));
    expect(visible(), contains('current step'));
    expect(visible(), contains('classification'));
    screen.resize(ScreenLayout.fromSize(30, 8, split: false));
    home.setOuter(screen.chat.bounds);
    io.output.clear();
    plugin.panel!.show();
    plans.repaintConsole();
    await pumpEventQueue();
    plugin.repaintConsole();
    expect(plugin.panel!.bounds.bottom, lessThan(screen.layout.inputRow));
    expect(visible(), contains('classification'));
    active = false;
    plugin.repaintConsole();
    expect(plugin.panel!.regionVisible, false);
    active = true;
    plugin.panel!.show();
    expect(focus.focused, same(plugin.panel));
    plugin.detachConsole();
    expect(focus.focused, same(home));
  });

  test(
      'invalid replies and terminal controls remain inspectable without UI errors',
      () {
    final e = request();
    e.receive('{"answers":"invalid"}');
    e.fail('invalidResponse');
    plugin.panel!.show(hierarchy: true);
    plugin.panel!.handleEvent(ArrowKey(ArrowDirection.up));
    plugin.panel!.handleEvent(ArrowKey(ArrowDirection.right));
    expect(plugin.panel!.details, true);
    plugin.panel!.handleEvent(ArrowKey(ArrowDirection.left));
    final malicious = request(inputId: '\x1b[2Jbad');
    malicious.receive('hello\x1b[2Jworld');
    expect(io.output.toString(), isNot(contains('hello\x1b[2Jworld')));
  });
}
