import 'package:test/test.dart';
import 'package:tina/session_commands/startup_session_picker.dart';
import 'package:tina_engine/tina_engine.dart';

SessionMeta session(String id, int day, {String? title}) => SessionMeta(
  id: id,
  title: title ?? id,
  createdAt: DateTime(2026, 1, day),
  updatedAt: DateTime(2026, 1, day),
  messageCount: 12,
  conversationCount: 1,
  cwd: '/projects/$id',
);

void main() {
  test('lists saved sessions newest first and returns the selected ID', () {
    final output = StringBuffer();
    final sessions = [session('older', 1), session('newer', 2)];
    final id = pickStartupSession(
      sessions,
      readLine: () => '2',
      write: output.write,
    );
    expect(id, 'older');
    expect(output.toString(), contains('1. newer'));
    expect(output.toString(), contains('2. older'));
    expect(output.toString(), contains('/projects/older'));
    expect(output.toString(), contains('12 messages'));
    expect(sessions.first.id, 'older');
  });

  test('invalid choices prompt again', () {
    final answers = ['0', '3', 'oops', '1'].iterator;
    final output = StringBuffer();
    final id = pickStartupSession(
      [session('chosen', 1)],
      readLine: () {
        answers.moveNext();
        return answers.current;
      },
      write: output.write,
    );
    expect(id, 'chosen');
    expect('Choose a number'.allMatches(output.toString()), hasLength(3));
  });

  for (final answer in [null, '', ' ', 'q', 'Q']) {
    test('cancel or EOF ($answer) returns no selection', () {
      expect(
        pickStartupSession(
          [session('saved', 1)],
          readLine: () => answer,
          write: (_) {},
        ),
        isNull,
      );
    });
  }

  test('no sessions reports and never reads input', () {
    final output = StringBuffer();
    expect(
      pickStartupSession(
        [],
        readLine: () => throw StateError('Unexpected input'),
        write: output.write,
      ),
      isNull,
    );
    expect(output.toString(), 'No saved sessions.\n');
  });

  test('saved metadata cannot emit terminal control sequences', () {
    final output = StringBuffer();
    pickStartupSession(
      [session('saved', 1, title: 'name\x1b[2J\nother')],
      readLine: () => '',
      write: output.write,
    );
    expect(output.toString(), isNot(contains('\x1b')));
    expect(output.toString(), contains('name [2J other'));
  });
}
