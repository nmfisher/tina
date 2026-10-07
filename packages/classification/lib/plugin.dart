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
  final trace = ClassificationTrace();
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
        for (final exchange in trace.exchanges.where(
          (e) => e.inputId == input.id,
        )) {
          exchange.fail('timeout');
        }
        token.cancel();
      });
      void outcome(String classifier, ClassificationOutcome value) {
        if (!current() || token.isCancelled) return;
        final matching = trace.exchanges.where(
          (e) => e.inputId == input.id && e.classifierId == classifier,
        );
        if (matching.isNotEmpty) matching.last.recordOutcome(value);
      }

      final result = await Future.any<UtteranceClassification?>([
        classifyAdaptiveUtterance(
          id: input.id,
          text: input.text,
          history: history,
          service: _TracedJudgments(
            lease.service,
            lease.budget.model,
            trace,
            input.id,
            input.text,
          ),
          budget: lease.budget,
          cancellation: token,
          store: categories,
          learner: learner == null
              ? null
              : _TracedLearner(learner!, trace, input.id),
          onIntent: (intent) => outcome(
            'intent',
            ClassificationOutcome(switch (intent.type) {
              IntentType.agentInstruction => 'Request to do work',
              IntentType.projectQuestion => 'Project question',
              IntentType.unclear => 'Unclear',
              null => intent.categoryLabel ?? 'Other',
            }, unclear: intent.type == IntentType.unclear),
          ),
          onGit: (git) => outcome(
            'git',
            ClassificationOutcome(
              git.unknown
                  ? 'Unclear'
                  : git.commands.isEmpty
                  ? 'No Git action'
                  : git.commands.map((c) => 'git $c').join(', '),
              unclear: git.unknown,
            ),
          ),
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
    if (status.inputId case final id?) trace.cancelPending(id);
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
    trace.close();
    unawaited(_changes.close());
  }
}

final class _TracedJudgments implements JudgmentService {
  _TracedJudgments(
    this.service,
    this.model,
    this.trace,
    this.inputId,
    this.inputText,
  );
  final JudgmentService service;
  final String model, inputId;
  final String inputText;
  final ClassificationTrace trace;

  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled == true)
      throw const JudgmentException(
        JudgmentFailure.cancelled,
        attempted: false,
      );
    final intent = request.questions.containsKey('intent');
    final previous = trace.exchanges
        .where(
          (e) =>
              e.inputId == inputId &&
              (intent
                  ? e.classifierId == 'intent' ||
                        e.classifierId == 'learn.intent'
                  : e.classifierId == 'intent' ||
                        e.classifierId == 'git' ||
                        e.classifierId == 'learn.git'),
        )
        .toList();
    final parent = previous.isEmpty ? null : previous.last.id;
    final exchange = trace.begin(
      inputId: inputId,
      title: intent ? 'Intent' : 'Git operations',
      classifierId: intent ? 'intent' : 'git',
      classifierName: intent ? 'Request type' : 'Git actions',
      inputText: inputText,
      trigger: parent == null
          ? null
          : previous.last.classifierId.startsWith('learn.')
          ? 'Retry after category discovery'
          : previous.last.classifierId == (intent ? 'intent' : 'git')
          ? 'Retry of ${intent ? 'Request type' : 'Git actions'}'
          : 'Request type → Request to do work',
      parentId: parent,
      questions: request.questions.map((id, q) => MapEntry(id, q.toJson())),
      request: request.toJson(
        model: service is TypeSafeJudgmentService
            ? (service as TypeSafeJudgmentService).config.model
            : model,
      ),
    );
    final unsubscribe = cancellation?.listen(
      () => exchange.fail('cancelled', cancelled: true),
    );
    try {
      final actual = service;
      final result = actual is TypeSafeJudgmentService
          ? await actual.evaluate(
              request,
              cancellation: cancellation,
              onResponse: exchange.receive,
            )
          : await actual.evaluate(request, cancellation: cancellation);
      exchange.recordAnswers(
        result.toJson()['answers'] as Map<String, Object?>,
      );
      exchange.complete(exchange.response.isEmpty ? result.toJson() : null);
      return result;
    } catch (error) {
      exchange.fail(
        error is JudgmentException
            ? error.toString()
            : 'invalid classifier response',
      );
      rethrow;
    } finally {
      unsubscribe?.call();
    }
  }
}

final class _TracedLearner implements CategoryLearner {
  _TracedLearner(this.learner, this.trace, this.inputId);
  final CategoryLearner learner;
  final ClassificationTrace trace;
  final String inputId;
  @override
  Future<CategoryProposal> propose({
    required CategoryQuestion question,
    required String input,
    required JudgmentCancellation cancellation,
  }) async {
    final previous = trace.exchanges
        .where((e) => e.inputId == inputId && e.classifierId == question.id)
        .toList();
    final parent = previous.isEmpty ? null : previous.last.id;
    final actual = learner;
    if (actual is MainAgentCategoryLearner)
      return actual.propose(
        question: question,
        input: input,
        cancellation: cancellation,
        trace: trace,
        inputId: inputId,
        parentId: parent,
      );
    final exchange = trace.begin(
      inputId: inputId,
      parentId: parent,
      title: 'Learn category · ${question.id}',
      classifierId: 'learn.${question.id}',
      classifierName: 'Category discovery',
      trigger: 'No existing category matched',
      inputText: input,
      request: {
        'question': question.question,
        'input': input,
        'categories': [
          for (final c in question.categories)
            {'id': c.id, 'question': c.question},
        ],
      },
    );
    final unsubscribe = cancellation.listen(
      () => exchange.fail('cancelled', cancelled: true),
    );
    try {
      final proposal = await actual.propose(
        question: question,
        input: input,
        cancellation: cancellation,
      );
      exchange.complete({
        'existing_category': proposal.existingId,
        'category': proposal.category == null
            ? null
            : {
                'id': proposal.category!.id,
                'label': proposal.category!.label,
                'description': proposal.category!.description,
                'question': proposal.category!.question,
              },
      });
      return proposal;
    } catch (error) {
      exchange.fail(
        error is JudgmentException
            ? error.toString()
            : 'invalid category proposal',
      );
      rethrow;
    } finally {
      unsubscribe();
    }
  }
}
