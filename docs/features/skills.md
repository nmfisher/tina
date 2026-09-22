# Skill registry

`tina_engine` provides a skill registry through the plugin system. The default
execution profile includes `skillsPlugin()`, which exposes `skillsServiceKey`.
Middleware can use this registry to choose when to load and supply instructions
(see [agent middleware](agent-middleware.md)). The registry itself does not scan `SKILL.md` files, add instructions
to prompts, execute resources, or expose an agent tool yet.

The design follows [DSH's skill subsystem](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/skills.md):
list small summaries first, load instruction bodies only when requested, and
resolve duplicate names using scope and source precedence.

## Register a skill from a plugin

```dart
final reviewPlugin = PluginDescriptor(
  id: 'example.review',
  requires: {skillsServiceKey},
  factory: FnPluginFactory((context) {
    registerSkill(context, 'review-skill', Skill(
      info: SkillInfo(
        name: 'review',
        description: 'Review code for correctness and missing tests.',
      ),
      content: 'Read the changed code and its callers before reviewing it.',
    ));
    return Object();
  }),
);
```

The returned registration handle can be disposed to remove the skill. Plugin
scope disposal also removes its registrations. Registration IDs are unique in
a scope; skill names may overlap across registrations and sources.

## Lazy sources

Implement `SkillSource` and call `registerSkillSource(context, id, source)`:

- `list(SkillContext)` returns a `SkillListing` of `SkillEntry` values.
- Each entry has `SkillInfo`, an optional opaque `key`, and a `rank` (default
  250). The key lets the source find a body without the registry knowing
  whether it came from a file, a network service, or memory.
- `load(SkillEntry, SkillContext)` returns the chosen `Skill`, or null if it is
  no longer available. Its metadata must match the listed entry.
- `SkillContext` supplies the caller's optional working directory and a
  cancellation signal. Sources should stop their own I/O when cancelled.

`SkillInfo` contains a kebab-case name, a description, model/user invocation
flags, and an optional absolute `resourceBase` URI. The registry never reads
resources itself. Bodies and source error details are excluded from catalogs.

## Lookup

```dart
final skills = context.require(skillsServiceKey).forScope(context.scope);
final catalog = await skills.list(cwd: projectRoot, use: SkillUse.model);
final skill = await skills.load('review', cwd: projectRoot, use: SkillUse.model);
```

Use `forScope(child)` for a child agent's view: inherited service lookup alone
still returns the parent's view. Child contributions override ancestors;
within one scope, lower rank wins, then registration order, then entry order.
Invocation flags filter the winner, so a hidden child skill never exposes a
shadowed parent skill. The default `SkillUse.internal` does not filter.

Discovery runs sources concurrently. A source failure or an explicitly
incomplete listing sets `catalog.complete` to false; `failedSources` identifies
failed contribution IDs. Available entries remain usable, but loading an
absent name throws if discovery was incomplete, rather than claiming absence.

There is no cache in this version. Each lookup sees current source data.
Registration changes during loading reject the result; callers can retry.
Removing a source interrupts its outstanding operations. Passing `cancelSignal`
to `list` or `load` throws `SkillCancelled` promptly, even if a source ignores
the signal; late replies are discarded. Source-owned resources should also be
registered with `context.own()` for cleanup.
