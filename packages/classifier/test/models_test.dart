import 'dart:convert';

import 'package:test/test.dart';
import 'package:classifier/judgments.dart';

void main() {
  late ChoiceQuestion route;
  late ScoreQuestion priority;
  late NoulQuestion blocked;
  late JudgmentRequest request;

  Map<String, dynamic> response() => jsonDecode(jsonEncode({
        'model': 'jev-resolved-version',
        'answers': {
          'route': {
            'type': 'choice',
            'choice': 'tests',
            'confidence': 0.8,
            'probabilities': {'code': 0.1, 'tests': 0.9}
          },
          'priority': {
            'type': 'score',
            'score': 0.75,
            'confidence': 0.4,
            'legend': {
              '0': 'Routine',
              '1': {'description': 'Urgent'}
            },
            'probabilities': {'0': 0.25, '1': 0.75}
          },
          'blocked': {'type': 'noul', 'noul': 0.2},
        },
        'usage': {'input_tokens': 128, 'output_tokens': 30},
      }));

  setUp(() {
    route = ChoiceQuestion('route',
        instructions: 'Which worker can do this?',
        criteria: {
          'code': null,
          'tests': ['Testing and validation']
        });
    priority = ScoreQuestion('priority', instructions: {
      'question': 'Urgency?'
    }, criteria: [
      'Routine',
      {'description': 'Urgent'}
    ]);
    blocked = NoulQuestion('blocked',
        instructions: 'Is user input required?',
        whenTrue: {'condition': 'Missing required information'},
        whenFalse: 'Can proceed');
    request = JudgmentRequest(
        state: {'task': 'Test the patch'},
        questions: [route, priority, blocked]);
  });

  test('mixed batch has documented wire shape and no chat fields', () {
    expect(jsonDecode(jsonEncode(request.toJson(model: 'jev-latest'))), {
      'model': 'jev-latest',
      'state': {'task': 'Test the patch'},
      'questions': {
        'route': {
          'type': 'choice',
          'instructions': 'Which worker can do this?',
          'criteria': {
            'code': null,
            'tests': ['Testing and validation']
          }
        },
        'priority': {
          'type': 'score',
          'instructions': {'question': 'Urgency?'},
          'criteria': [
            'Routine',
            {'description': 'Urgent'}
          ]
        },
        'blocked': {
          'type': 'noul',
          'instructions': 'Is user input required?',
          'criteria': {
            'true': {'condition': 'Missing required information'},
            'false': 'Can proceed'
          }
        },
      },
    });
  });

  test('typed handles return typed answers, structured legend, and usage', () {
    final result = JudgmentResult.fromJson(response(), request: request);
    final ChoiceAnswer choice = result.answer(route);
    final ScoreAnswer score = result.answer(priority);
    final NoulAnswer noul = result.answer(blocked);
    expect(choice.choice, 'tests');
    expect(choice.probabilities['tests'], 0.9);
    expect(score.legend[1], {'description': 'Urgent'});
    expect(score.probabilities[0], 0.25);
    expect(score.normalized, 0.75);
    expect(noul.noul, 0.2);
    expect(result.model, 'jev-resolved-version');
    expect(result.usage.inputTokens, 128);
    expect(result.usage.outputTokens, 30);
    expect(() => result.answers.clear(), throwsUnsupportedError);
    expect(() => choice.probabilities.clear(), throwsUnsupportedError);
    expect(() => (score.legend[1] as Map).clear(), throwsUnsupportedError);
  });

  test('answer correlation does not depend on response insertion order', () {
    final json = response();
    json['answers'] = Map.fromEntries(
        (json['answers'] as Map<String, dynamic>).entries.toList().reversed);
    expect(JudgmentResult.fromJson(json, request: request).answer(blocked).noul,
        0.2);
  });

  test('same ID with different schema cannot retrieve answer', () {
    final result = JudgmentResult.fromJson(response(), request: request);
    expect(() => result.answer(NoulQuestion('route', instructions: 'Other?')),
        throwsArgumentError);
  });

  test('deep snapshot prevents caller mutation after construction', () {
    final source = <String, Object?>{
      'nested': <Object?>['original']
    };
    final options = <String, Object?>{'a': source, 'b': null};
    final question =
        ChoiceQuestion('q', instructions: source, criteria: options);
    final batch = JudgmentRequest(state: source, questions: [question]);
    (source['nested'] as List).add('changed');
    options.clear();
    expect(batch.state.value, {
      'nested': ['original']
    });
    expect(question.instructions!.value, {
      'nested': ['original']
    });
    expect(question.criteria['a'], {
      'nested': ['original']
    });
    expect(() => ((batch.state.value as Map)['nested'] as List).add('x'),
        throwsUnsupportedError);
  });

  test('advanced nullable instructions and levels are preserved', () {
    final q = ScoreQuestion('q', instructions: null, criteria: [null, 'yes']);
    expect(q.toJson()['instructions'], isNull);
    final batch = JudgmentRequest(state: ['input'], questions: [q]);
    final result = JudgmentResult.fromJson({
      'model': 'jev-latest',
      'usage': {},
      'answers': {
        'q': {
          'type': 'score',
          'score': 1,
          'confidence': 1,
          'legend': {'0': null, '1': 'yes'},
          'probabilities': {'0': 0, '1': 1}
        }
      },
    }, request: batch);
    expect(result.answer(q).legend[0], isNull);
  });

  test('optional noul criteria omitted and missing counters remain unknown',
      () {
    expect(
        NoulQuestion('q', instructions: 'Ready?')
            .toJson()
            .containsKey('criteria'),
        isFalse);
    final json = response()..['usage'] = <String, Object?>{};
    final usage = JudgmentResult.fromJson(json, request: request).usage;
    expect(usage.inputTokens, isNull);
    expect(usage.outputTokens, isNull);
  });

  test('reject invalid input before transport', () {
    final cyclic = <Object?>[];
    cyclic.add(cyclic);
    for (final state in [
      1,
      true,
      DateTime(2026),
      {'nan': double.nan},
      {1: 'bad key'},
      cyclic,
      {'object': Object()}
    ]) {
      expect(() => JudgmentRequest(state: state, questions: [blocked]),
          throwsArgumentError);
    }
    expect(
        () => JudgmentRequest(state: '', questions: []), throwsArgumentError);
    expect(() => JudgmentRequest(state: '', questions: [blocked, blocked]),
        throwsArgumentError);
    expect(() => NoulQuestion(' ', instructions: '?'), throwsArgumentError);
    expect(() => ChoiceQuestion('q', instructions: '?', criteria: {}),
        throwsArgumentError);
    expect(() => ScoreQuestion('q', instructions: '?', criteria: ['one']),
        throwsArgumentError);
    expect(
        () => ScoreQuestion('q',
            instructions: '?', criteria: List.filled(11, 'x')),
        throwsArgumentError);
    expect(
        () => ChoiceQuestion('q',
            instructions: '?',
            criteria: {for (var i = 0; i < 256; i++) '$i': null}),
        throwsArgumentError);
  });

  final corruptions = <String, void Function(Map<String, dynamic>)>{
    'missing answer': (j) => (j['answers'] as Map).remove('blocked'),
    'extra answer': (j) => j['answers']['extra'] = {'type': 'noul', 'noul': 1},
    'wrong type': (j) => j['answers']['blocked']['type'] = 'choice',
    'unknown type': (j) => j['answers']['blocked']['type'] = 'text',
    'prose answer': (j) => j['answers']['route'] = 'tests',
    'unknown choice': (j) => j['answers']['route']['choice'] = 'deploy',
    'missing option': (j) =>
        (j['answers']['route']['probabilities'] as Map).remove('code'),
    'extra option': (j) => j['answers']['route']['probabilities']['extra'] = 0,
    'invalid sum': (j) => j['answers']['route']['probabilities']['tests'] = 0.1,
    'negative probability': (j) =>
        j['answers']['route']['probabilities']['code'] = -0.1,
    'nonfinite': (j) => j['answers']['blocked']['noul'] = double.infinity,
    'noul out of range': (j) => j['answers']['blocked']['noul'] = 1.1,
    'string number': (j) => j['answers']['blocked']['noul'] = '0.2',
    'missing confidence': (j) =>
        (j['answers']['route'] as Map).remove('confidence'),
    'confidence out of range': (j) => j['answers']['route']['confidence'] = -1,
    'score out of range': (j) => j['answers']['priority']['score'] = 2,
    'legend mismatch': (j) => j['answers']['priority']['legend']['0'] = 'Other',
    'level missing': (j) =>
        (j['answers']['priority']['legend'] as Map).remove('1'),
    'negative usage': (j) => j['usage']['input_tokens'] = -1,
    'fractional usage': (j) => j['usage']['input_tokens'] = 1.5,
    'missing usage': (j) => j.remove('usage'),
    'missing model': (j) => j.remove('model'),
  };
  for (final entry in corruptions.entries) {
    test('rejects ${entry.key} atomically', () {
      final json = response();
      entry.value(json);
      expect(() => JudgmentResult.fromJson(json, request: request),
          throwsFormatException);
    });
  }

  test('extra metadata is tolerated without treating it as an answer', () {
    final json = response()..['future_metadata'] = {'key': true};
    json['answers']['blocked']['future_field'] = 'extra';
    expect(JudgmentResult.fromJson(json, request: request).answer(blocked).noul,
        0.2);
  });
}
