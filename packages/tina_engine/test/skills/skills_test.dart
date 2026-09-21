import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

Skill skill(String name, String content,
        {bool model = true, bool user = true}) =>
    Skill(
      info: SkillInfo(
          name: name,
          description: 'Use $name',
          modelInvocable: model,
          userInvocable: user,
          resourceBase: Uri.parse('https://example.test/skills/$name/')),
      content: content,
    );

class Source implements SkillSource {
  List<SkillEntry> entries;
  final Map<Object?, Skill> bodies;
  int loads = 0;
  String? cwd;
  bool complete = true;
  bool fail = false;
  Completer<void>? loading;
  Completer<Skill?>? pending;
  Source(this.entries, this.bodies);
  @override
  Future<SkillListing> list(SkillContext context) async {
    cwd = context.cwd;
    if (fail) throw StateError('private failure details');
    return SkillListing(entries, complete: complete);
  }

  @override
  Future<Skill?> load(SkillEntry entry, SkillContext context) async {
    loads++;
    loading?.complete();
    return pending?.future ?? Future.value(bodies[entry.key]);
  }
}

PluginContext context(PluginScope scope) => PluginContext(
      plugin: PluginDescriptor(
          id: 'test', factory: FnPluginFactory((_) => Object())),
      scope: scope,
    );

void main() {
  late PluginScope root;
  late Skills skills;
  setUp(() {
    root = PluginScope('root');
    skills = Skills(root);
  });
  tearDown(() => root.dispose());

  test('service plugin resolves and registrations are owned by plugin scope',
      () async {
    final runtime = PluginRuntime(name: 'skills', plugins: [
      skillsPlugin(),
      PluginDescriptor(
          id: 'bundle',
          requires: {skillsServiceKey},
          factory: FnPluginFactory((ctx) {
            registerSkill(
                ctx, 'release', skill('release', 'release instructions'));
            return ctx.require(skillsServiceKey);
          })),
    ]);
    await runtime.activate();
    final service = runtime.scope.lookup(skillsServiceKey)!;
    expect((await service.load('release'))!.content, 'release instructions');
    await runtime.dispose();
    await expectLater(service.list(), throwsStateError);
  });

  test('catalog is lazy, sorted and sees changes without a cache', () async {
    final a = skill('alpha', 'alpha body');
    final z = skill('zulu', 'zulu body');
    final source = Source(
        [SkillEntry(z.info, key: 7), SkillEntry(a.info, key: 9)], {7: z, 9: a});
    registerSkillSource(context(root), 'files', source);
    final catalog = await skills.list(cwd: '/project');
    expect(catalog.complete, isTrue);
    expect(catalog.skills.map((s) => s.name), ['alpha', 'zulu']);
    expect(source.cwd, '/project');
    expect(source.loads, 0);
    expect((await skills.load('alpha'))!.content, 'alpha body');
    expect(source.loads, 1);
    source.entries = [SkillEntry(z.info, key: 7)];
    expect(await skills.load('alpha'), isNull);
    expect(() => catalog.skills.clear(), throwsUnsupportedError);
  });

  test('nearest scope wins; rank then registration order break ties', () async {
    registerSkill(context(root), 'parent', skill('review', 'parent'), rank: 0);
    final child = root.child('child');
    addTearDown(child.dispose);
    final local = skills.forScope(child);
    final first = registerSkill(
        context(child), 'first', skill('review', 'first'),
        rank: 30);
    registerSkill(context(child), 'second', skill('review', 'second'),
        rank: 30);
    expect((await local.load('review'))!.content, 'first');
    final winner = registerSkill(
        context(child), 'rank', skill('review', 'rank'),
        rank: 20);
    expect((await local.load('review'))!.content, 'rank');
    await winner.dispose();
    await first.dispose();
    expect((await local.load('review'))!.content, 'second');
    expect((await skills.load('review'))!.content, 'parent');
    final sibling = root.child('sibling');
    addTearDown(sibling.dispose);
    expect((await skills.forScope(sibling).load('review'))!.content, 'parent');
  });

  test('source entry order breaks ties and incomplete listings are explicit',
      () async {
    final first = skill('review', 'first');
    final second = skill('review', 'second');
    final source = Source([
      SkillEntry(first.info, key: 1),
      SkillEntry(second.info, key: 2),
    ], {
      1: first,
      2: second
    })
      ..complete = false;
    registerSkillSource(context(root), 'files', source);
    final catalog = await skills.list();
    expect(catalog.complete, isFalse);
    expect(catalog.failedSources, isEmpty);
    expect((await skills.load('review'))!.content, 'first');
    await expectLater(skills.load('missing'), throwsStateError);
  });

  test('a newly registered override invalidates an in-flight body load',
      () async {
    final value = skill('review', 'old');
    final source = Source([SkillEntry(value.info)], {})
      ..loading = Completer<void>()
      ..pending = Completer<Skill?>();
    registerSkillSource(context(root), 'files', source);
    final loading = skills.load('review');
    final check = expectLater(loading, throwsStateError);
    await source.loading!.future;
    registerSkill(context(root), 'override', skill('review', 'new'), rank: 0);
    source.pending!.complete(value);
    await check;
    expect((await skills.load('review'))!.content, 'new');
  });

  test('invocation restrictions never reveal a shadowed parent skill',
      () async {
    registerSkill(context(root), 'parent', skill('review', 'parent'));
    final child = root.child('child');
    addTearDown(child.dispose);
    registerSkill(context(child), 'private',
        skill('review', 'private', model: false, user: false));
    final local = skills.forScope(child);
    expect((await local.list(use: SkillUse.model)).skills, isEmpty);
    expect(await local.load('review', use: SkillUse.user), isNull);
    expect((await local.load('review'))!.content, 'private');
  });

  test('failed discovery reports incomplete instead of authoritative absence',
      () async {
    final bad = Source([], {})..fail = true;
    registerSkillSource(context(root), 'broken', bad);
    registerSkill(context(root), 'good', skill('ready', 'usable'));
    final catalog = await skills.list();
    expect(catalog.complete, isFalse);
    expect(catalog.failedSources, ['broken']);
    expect(catalog.skills.single.name, 'ready');
    expect((await skills.load('ready'))!.content, 'usable');
    await expectLater(skills.load('missing'), throwsStateError);
    bad.fail = false;
    expect((await skills.list()).complete, isTrue);
  });

  test('source disposal interrupts a pending load and ignores late replies',
      () async {
    final value = skill('review', 'instructions');
    final source = Source([SkillEntry(value.info)], {})
      ..loading = Completer<void>()
      ..pending = Completer<Skill?>();
    final registration = registerSkillSource(context(root), 'files', source);
    final loading = skills.load('review');
    final check = expectLater(loading, throwsA(isA<SkillCancelled>()));
    await source.loading!.future;
    await registration.dispose();
    await check;
    source.pending!.complete(value);
    expect(await skills.load('review'), isNull);
  });

  test(
      'caller cancellation interrupts loading and an already cancelled call does no work',
      () async {
    final value = skill('review', 'instructions');
    final source = Source([SkillEntry(value.info)], {})
      ..loading = Completer<void>()
      ..pending = Completer<Skill?>();
    registerSkillSource(context(root), 'files', source);
    final cancel = Completer<void>();
    final check = expectLater(
        skills.load('review', cancelSignal: cancel.future),
        throwsA(isA<SkillCancelled>()));
    await source.loading!.future;
    cancel.complete();
    await check;
    source.pending!.complete(value);
    await expectLater(skills.load('review', cancelSignal: cancel.future),
        throwsA(isA<SkillCancelled>()));
    expect(source.loads, 1);
  });

  test('malformed names and source substitutions are rejected', () async {
    expect(() => SkillInfo(name: 'Bad Name', description: 'description'),
        throwsArgumentError);
    final value = skill('review', 'body');
    registerSkillSource(context(root), 'bad',
        Source([SkillEntry(value.info)], {null: skill('different', 'body')}));
    await expectLater(skills.load('review'), throwsStateError);
  });
}
