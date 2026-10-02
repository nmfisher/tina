import 'dart:async';
import 'dart:io' show File;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'config.dart';
import 'judgments.dart';
import 'typesafe_classifier.dart';
import 'utterance.dart';
import 'category_store.dart';
export 'utterance.dart';

InputCategoryStore openClassificationCategories(String configPath) =>
    FileInputCategoryStore(
      File(configPath).absolute.parent.uri
          .resolve('classification/categories.json')
          .toFilePath(),
    );

ClassificationLease? openConfiguredClassification(
  String configPath, {
  Map<String, String>? environment,
}) {
  final config = readClassificationConfig(configPath, environment: environment);
  if (config == null) return null;
  final service = TypeSafeJudgmentService(config: config);
  return ClassificationLease(
    service: service,
    budget: config.requestBudget,
    close: service.close,
  );
}

enum ClassificationPhase {
  idle,
  checking,
  learning,
  ready,
  unavailable,
  cancelled,
}

final class ClassificationStatus {
  const ClassificationStatus(
    this.phase, {
    this.inputId,
    this.result,
    this.reason,
  });
  final ClassificationPhase phase;
  final String? inputId;
  final UtteranceClassification? result;
  final String? reason;
  String get label => switch (phase) {
    ClassificationPhase.idle => 'no input classified yet',
    ClassificationPhase.checking => 'classifying…',
    ClassificationPhase.learning => 'learning category…',
    ClassificationPhase.ready => result!.label,
    ClassificationPhase.unavailable => 'unavailable: $reason',
    ClassificationPhase.cancelled => 'cancelled',
  };
}

/// A single input's classifier service. The plugin owns and closes the lease.
final class ClassificationLease {
  ClassificationLease({
    required this.service,
    required this.budget,
    required this.close,
  });
  final JudgmentService service;
  final JudgmentRequestBudget budget;
  final void Function() close;
}

/// Informational input classification. Background work never rewrites input,
/// grants permissions, or adds predictions to the model's prompt/transcript.
class ClassificationPlugin extends AgentPlugin {
  ClassificationPlugin({
    required this.terminal,
    required this.open,
    this.timeout = const Duration(seconds: 30),
    InputCategoryStore? categories,
    this.learner,
  }) : categories = categories ?? MemoryInputCategoryStore();
  factory ClassificationPlugin.configured({
    required Terminal terminal,
    required String configPath,
    Map<String, String>? environment,
    required LlmProvider Function() createProvider,
  }) => ClassificationPlugin(
    terminal: terminal,
    open: () =>
        openConfiguredClassification(configPath, environment: environment),
    categories: openClassificationCategories(configPath),
    learner: MainAgentCategoryLearner(createProvider),
    timeout: const Duration(seconds: 90),
  );

  final Terminal terminal;
  final ClassificationLease? Function() open;
  final Duration timeout;
  final InputCategoryStore categories;
  final CategoryLearner? learner;
  @override
  String get id => 'tina/classification';
  // Observe the accepted text after ordinary input guards and rewrites.
  @override
  int get order => 1000;
  ClassificationStatus _status = const ClassificationStatus(
    ClassificationPhase.idle,
  );
  ClassificationStatus get status => _status;
  final _changes = StreamController<ClassificationStatus>.broadcast(sync: true);
  Stream<ClassificationStatus> get changes => _changes.stream;
  JudgmentCancellation? _active;
  void Function()? _closeActive;
  bool _closed = false;

  void _publish(ClassificationStatus value) {
    if (_closed) return;
    _status = value;
    _changes.add(value);
  }

  @override
  void onInput(TurnContext context) {
    if (_closed || context.cancelled) return;
    _stop();
    final token = JudgmentCancellation();
    _active = token;
    final input = context.input;
    final history = List<Message>.of(context.messages);
    _publish(
      ClassificationStatus(ClassificationPhase.checking, inputId: input.id),
    );
    unawaited(
      context.whenCancelled.then((_) {
        if (identical(_active, token)) {
          _stop();
          _publish(
            ClassificationStatus(
              ClassificationPhase.cancelled,
              inputId: input.id,
            ),
          );
        }
      }),
    );
    unawaited(_classify(input, history, token));
  }

  Future<void> _classify(
    Input input,
    List<Message> history,
    JudgmentCancellation token,
  ) async {
    ClassificationLease? lease;
    Timer? timer;
    final stopped = Completer<void>();
    final unsubscribe = token.listen(() {
      if (!stopped.isCompleted) stopped.complete();
    });
    var timedOut = false;
    bool current() => !_closed && identical(_active, token);
    try {
      lease = open();
      if (lease == null) {
        if (current())
          _publish(
            ClassificationStatus(
              ClassificationPhase.unavailable,
              inputId: input.id,
              reason: 'configure [typesafe].api_key or TYPESAFE_API_KEY',
            ),
          );
        return;
      }
      var released = false;
      void close() {
        if (!released) {
          released = true;
          lease!.close();
        }
      }

      _closeActive = close;
      timer = Timer(timeout, () {
        timedOut = true;
        token.cancel();
      });
      final result = await Future.any<UtteranceClassification?>([
        classifyAdaptiveUtterance(
          id: input.id,
          text: input.text,
          history: history,
          service: lease.service,
          budget: lease.budget,
          cancellation: token,
          store: categories,
          learner: learner,
          onLearning: (_) {
            if (current() && !token.isCancelled) {
              _publish(
                ClassificationStatus(
                  ClassificationPhase.learning,
                  inputId: input.id,
                ),
              );
            }
          },
        ),
        stopped.future.then((_) => null),
      ]);
      if (!current()) return;
      if (timedOut) {
        _publish(
          ClassificationStatus(
            ClassificationPhase.unavailable,
            inputId: input.id,
            reason: 'timeout',
          ),
        );
      } else if (!token.isCancelled && result != null) {
        _publish(
          ClassificationStatus(
            ClassificationPhase.ready,
            inputId: input.id,
            result: result,
          ),
        );
      }
    } catch (error) {
      if (current())
        _publish(
          ClassificationStatus(
            ClassificationPhase.unavailable,
            inputId: input.id,
            reason: timedOut
                ? 'timeout'
                : error is JudgmentException
                ? error.failure.name
                : 'invalid configuration or classifier response',
          ),
        );
    } finally {
      timer?.cancel();
      unsubscribe();
      // A superseding input may already have closed this lease.
      if (current()) {
        _closeActive?.call();
        _closeActive = null;
        _active = null;
      }
    }
  }

  void _stop() {
    final token = _active;
    _active = null;
    token?.cancel();
    _closeActive?.call();
    _closeActive = null;
  }

  @override
  List<Command> get commands => [
    Command(
      name: 'classification',
      description: 'show the latest user intent and Git classification',
      handler: (arguments) async {
        if (arguments.trim() == 'categories') {
          for (final question in await categories.read()) {
            terminal.writeln(
              '${question.question} (${question.categories.length}/$maxInputCategories)',
            );
            final sorted = question.categories.toList()
              ..sort((a, b) => b.selections.compareTo(a.selections));
            for (final category in sorted) {
              terminal.writeln(
                '  ${category.id}: ${category.label} — ${category.selections} selections',
              );
              terminal.writeln('    ${category.question}');
            }
            terminal.writeln('  other: ${question.otherSelections} selections');
          }
        } else {
          terminal.writeln(
            'Classification${status.inputId == null ? '' : ' (${status.inputId})'}: ${status.label}',
          );
        }
      },
    ),
  ];

  @override
  void closeSession() {
    if (_closed) return;
    _closed = true;
    _stop();
    unawaited(_changes.close());
  }
}
