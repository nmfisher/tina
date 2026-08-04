import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_tool.dart';

void main() {
  Tool fake(String name, [String result = 'ok']) =>
      FakeTool(name, (_) async => ToolResult(result));

  test('lookup by schema name; missing name is null', () {
    final r = ToolRegistry([fake('a'), fake('b')]);
    expect(r['a'], isNotNull);
    expect(r['b'], isNotNull);
    expect(r['nope'], isNull);
  });

  test('all exposes every registered tool', () {
    final r = ToolRegistry([fake('a'), fake('b'), fake('c')]);
    expect(r.all.map((t) => t.schema.name).toSet(), {'a', 'b', 'c'});
  });

  test("schemas is the tools' schemas in registry order", () {
    final r = ToolRegistry([fake('a'), fake('b')]);
    expect(r.schemas.map((s) => s.name), ['a', 'b']);
  });

  test('duplicate names: the later entry shadows the earlier (last-wins)', () {
    final first = fake('x', 'first');
    final second = fake('x', 'second');
    final r = ToolRegistry([first, second]);
    expect(identical(r['x'], second), isTrue);
  });

  test('composition via [...base.all, ...] overrides a base tool', () {
    final base = ToolRegistry([fake('bash', 'base')]);
    final override = fake('bash', 'extended');
    final composed = ToolRegistry([...base.all, override]);
    expect(identical(composed['bash'], override), isTrue);
  });

  test('a registered FakeTool executes via its handler', () async {
    final r = ToolRegistry([fake('echo', 'echoed')]);
    final res = await r['echo']!.execute({});
    expect(res.content, 'echoed');
    expect(res.isError, isFalse);
  });
}
