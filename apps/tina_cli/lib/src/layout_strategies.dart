import 'package:tina_console/tina_console.dart'
    show FocusScreenStrategy, TwoColumnScreenStrategy;
import 'package:tina_layout/tina_layout.dart'
    show BuiltinLayoutStrategy, LayoutStrategy;

/// The layout strategies this binary knows by name: the built-in solver
/// and the shipped presets, plus anything a composition root registered
/// via [registerLayoutStrategy] before `SessionAssembly.start`.
///
/// This is the native strategies-directory equivalent: custom
/// strategies are classes in the application's Dart code, compiled in
/// and registered by name — there is no runtime code loading (AOT
/// binaries cannot load Dart at runtime, and native strategies are
/// trusted code with no isolation boundary anyway). See
/// docs/native-layout-strategies.md.
final Map<String, LayoutStrategy Function()> layoutStrategyFactories = {
  'default': BuiltinLayoutStrategy.new,
  'focus': FocusScreenStrategy.new,
  'two-column': TwoColumnScreenStrategy.new,
};

/// Register a workspace-declared layout strategy under [name]. Call
/// before the session assembly starts; the name becomes valid in config
/// (`layout_strategy = "<name>"`) and in `/layout <name>`.
void registerLayoutStrategy(String name, LayoutStrategy Function() factory) {
  if (!RegExp(r'^[a-z][a-z0-9_-]*(/[a-z][a-z0-9_-]*)?$').hasMatch(name)) {
    throw ArgumentError.value(name, 'name',
        'strategy names are lowercase words: a-z, 0-9, - and _');
  }
  layoutStrategyFactories[name] = factory;
}
