import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';

/// A capability is a typed constructor dependency, resolved once at load time.
/// It is not a global registry available to running plugins.
final class PluginCapability<T extends Object> {
  const PluginCapability(this.name);
  final String name;
  bool accepts(Object value) => value is T;
}

/// Declarative factory. Dependencies are passed as typed constructor arguments.
final class PluginDefinition<C> {
  PluginDefinition(this.id, AgentPlugin Function(C) create,
      {required String description,
      this.provides = const [],
      this.settings = const [],
      this.live = false})
      : description = _description(description),
        requires = const [],
        _create = ((context, _) => create(context));

  PluginDefinition._(this.id, String description, this.requires, this.provides,
      this._create, this.live, this.settings)
      : description = _description(description);

  static PluginDefinition<C> dependingOn<C, D extends Object>(String id,
          {required String description,
          required PluginCapability<D> dependency,
          required AgentPlugin Function(C, D) create,
          List<PluginCapability<Object>> provides = const [],
          List<SettingDefinition<Object>> settings = const [],
          bool live = false}) =>
      PluginDefinition._(
          id,
          description,
          [dependency],
          provides,
          (context, dependencies) => create(context, dependencies.single as D),
          live,
          settings);

  static PluginDefinition<C>
      dependingOn2<C, A extends Object, B extends Object>(String id,
              {required String description,
              required PluginCapability<A> first,
              required PluginCapability<B> second,
              required AgentPlugin Function(C, A, B) create,
              List<PluginCapability<Object>> provides = const [],
              List<SettingDefinition<Object>> settings = const [],
              bool live = false}) =>
          PluginDefinition._(
              id,
              description,
              [first, second],
              provides,
              (context, values) =>
                  create(context, values[0] as A, values[1] as B),
              live,
              settings);

  /// Opt-in: resources and background work support between-turn detach/reload.
  final bool live;
  final String id;

  /// User-facing explanation available without constructing the plugin.
  final String description;
  final List<SettingDefinition<Object>> settings;

  static String _description(String value) {
    final text = value.trim();
    if (text.isEmpty)
      throw ArgumentError('plugin description must not be empty');
    return text;
  }

  final List<PluginCapability<Object>> requires;
  final List<PluginCapability<Object>> provides;
  final AgentPlugin Function(C, List<Object>) _create;

  AgentPlugin build(C context, List<Object> dependencies) =>
      _create(context, dependencies);
}

/// Application-level model access, independent of any concrete provider plugin.
abstract interface class ModelAccess {
  LlmProvider mainProvider(String model);
  LlmProvider childProvider(String model);
}

const modelAccess = PluginCapability<ModelAccess>('tina/model-access');
