import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

class Observer implements InstructionObserver {
  final loads = <InstructionLoad>[];
  @override
  void onInstructionsLoaded(InstructionLoad load) => loads.add(load);
}

PluginContext plugin(PluginScope scope) => PluginContext(
    plugin:
        PluginDescriptor(id: 'test', factory: FnPluginFactory((_) => Object())),
    scope: scope);

Future<String> loadPrompt(String identity,
    {required String cwd,
    PluginScope? scope,
    bool loadProjectContext = true}) async {
  final base = resolveIdentityPrompt(identity,
      cwd: cwd, loadProjectContext: loadProjectContext);
  final context = AgentContext(
      stage: AgentStage.request,
      cwd: cwd,
      loadProjectContext: loadProjectContext,
      model: 'test');
  try {
    final result = await AgentsInstructions(scope).beforeRequest(context,
        AgentRequest(system: base, messages: const [], tools: const []));
    return result.value!.system;
  } finally {
    context.close();
  }
}

void main() {
  late Directory dir;
  late PluginScope scope;
  late Observer observer;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina_instructions_');
    scope = PluginScope('instructions');
    observer = Observer();
    plugin(scope).register(observer, id: 'observer');
  });
  tearDown(() async {
    await scope.dispose();
    dir.deleteSync(recursive: true);
  });

  test('middleware loads carry order, scope and stable revisions', () async {
    final child = Directory('${dir.path}/child')..createSync();
    File('${dir.path}/AGENTS.md').writeAsStringSync('outer');
    final inner = File('${child.path}/AGENTS.md')..writeAsStringSync('inner');
    final before = await loadPrompt('identity', cwd: child.path);
    final after = await loadPrompt('identity', cwd: child.path, scope: scope);
    expect(after, before);
    final instructions = observer.loads.single.instructions;
    expect(instructions.map((i) => i.text), ['outer', 'inner']);
    expect(instructions.last.scope, child.uri);
    expect(instructions.last.source, inner.uri);
    expect(instructions.every((i) => i.complete), isTrue);
    final ref = instructions.last.ref;
    await loadPrompt('identity', cwd: child.path, scope: scope);
    expect(ref.matches(observer.loads.last.instructions.last), isTrue);
    inner.writeAsStringSync('edited');
    await loadPrompt('identity', cwd: child.path, scope: scope);
    expect(ref.matches(observer.loads.last.instructions.last), isFalse);
    inner.deleteSync();
    await loadPrompt('identity', cwd: child.path, scope: scope);
    expect(observer.loads.last.instructions.map((i) => i.text), ['outer']);
  });

  test(
      'untrusted prompts do not publish; removed observers do not receive loads',
      () async {
    File('${dir.path}/AGENTS.md').writeAsStringSync('private');
    await loadPrompt('identity',
        cwd: dir.path, scope: scope, loadProjectContext: false);
    expect(observer.loads, isEmpty);
    final child = scope.child('child');
    await loadPrompt('identity', cwd: dir.path, scope: child);
    expect(observer.loads, hasLength(1));
    await scope.dispose();
    await loadPrompt('identity', cwd: dir.path, scope: child);
    expect(observer.loads, hasLength(1));
  });

  test(
      'truncated input is marked incomplete and revisions cover the full source',
      () async {
    final file = File('${dir.path}/AGENTS.md');
    final prefix = 'x' * (50 * 1024);
    file.writeAsStringSync('${prefix}one');
    await loadPrompt('identity', cwd: dir.path, scope: scope);
    final first = observer.loads.single.instructions.single;
    expect(first.complete, isFalse);
    expect(observer.loads.single.complete, isFalse);
    file.writeAsStringSync('${prefix}two');
    await loadPrompt('identity', cwd: dir.path, scope: scope);
    final second = observer.loads.last.instructions.single;
    expect(second.text, first.text);
    expect(second.revision, isNot(first.revision));
  });

  test('skill catalogs stay lazy; only admitted loaded bodies are observed',
      () async {
    final skill = Skill(
        info: SkillInfo(name: 'example', description: 'Example'),
        content: 'Skill body');
    final registration = registerSkill(plugin(scope), 'example', skill);
    final skills = Skills(scope);
    await skills.list();
    expect(observer.loads, isEmpty);
    expect(await skills.load('missing'), isNull);
    expect(observer.loads, isEmpty);
    expect(await skills.load('example', cwd: dir.path), same(skill));
    final load = observer.loads.single;
    expect(load.kind, InstructionKind.skill);
    expect(load.instructions.single.text, skill.content);
    expect(load.instructions.single.source, isNull);
    await registration.dispose();
    expect(await skills.load('example'), isNull);
    expect(observer.loads, hasLength(1));
  });
}
