import '../registry.dart';
import 'anthropic_descriptor.dart';
import 'cerebras_descriptor.dart';
import 'deepseek_descriptor.dart';
import 'gemini_descriptor.dart';
import 'glm_descriptor.dart';
import 'grok_descriptor.dart';
import 'hetzner_descriptor.dart';
import 'longcat_descriptor.dart';
import 'mistral_descriptor.dart';
import 'nim_descriptor.dart';
import 'novita_descriptor.dart';
import 'openai_descriptor.dart';
import 'openrouter_descriptor.dart';
import 'qwen_descriptor.dart';
import 'qwencloud_descriptor.dart';
import 'tencent_descriptor.dart';

/// Registers every built-in provider descriptor on [registry]. Called once
/// from `main()` at startup, before any config-file providers are layered on.
void registerBuiltins(ProviderRegistry registry) {
  registry
    ..register(anthropicDescriptor)
    ..register(cerebrasDescriptor)
    ..register(geminiDescriptor)
    ..register(openaiDescriptor)
    ..register(openrouterDescriptor)
    ..register(deepseekDescriptor)
    ..register(glmDescriptor)
    ..register(grokDescriptor)
    ..register(hetznerDescriptor)
    ..register(longcatDescriptor)
    ..register(mistralDescriptor)
    ..register(nimDescriptor)
    ..register(novitaDescriptor)
    ..register(qwenDescriptor)
    ..register(qwencloudDescriptor)
    ..register(tencentDescriptor);
}

/// A [ProviderRegistry] with every built-in provider registered. Convenience
/// for call sites that want the default catalog without spelling out
/// [registerBuiltins] on two lines. Pass [env] to build the registry against a
/// specific environment (e.g. one that already layers the user-config overlay
/// over `Platform.environment`); the default reads `Platform.environment`.
ProviderRegistry builtinRegistry({Map<String, String>? env}) {
  final r = ProviderRegistry(env: env);
  registerBuiltins(r);
  return r;
}
