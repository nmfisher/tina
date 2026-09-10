import 'package:tina_engine/tina_engine.dart';

/// Releases owned resources in reverse acquisition order, even if one fails.
/// Register only owned resources; borrowed dependencies stay with their owner.
///
/// App-layer alias for the engine's [ScopeResources]: one cleanup
/// implementation for every plugin scope and every app composition.
typedef RuntimeResources = ScopeResources;
