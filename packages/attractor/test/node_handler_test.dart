import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

/// The node-kind seam: [NodeHandlerRegistry] maps a node to its handler by
/// the spec's resolve order — explicit `type` → shape-to-type → default
/// (`codergen`, or the registry's [NodeHandlerRegistry.defaultHandler] for a
/// type nothing registered). These tests pin the order and the unknown-type
/// fallback; they add no new kinds and change no semantics.
void main() {
  NodeHandlerRegistry registry() {
    final r = NodeHandlerRegistry();
    r.register('start', _TagHandler('start'));
    r.register('exit', _TagHandler('exit'));
    r.register('conditional', _TagHandler('conditional'));
    r.register('codergen', _TagHandler('codergen'));
    r.register('wait.human', _TagHandler('wait.human'));
    return r;
  }

  group('NodeHandlerRegistry resolve order', () {
    test('explicit type beats the shape mapping', () {
      final r = registry();
      // shape=diamond would map to `conditional`; the explicit type wins.
      final node = PipelineNode(id: 'n', attrs: {
        'shape': 'diamond',
        'type': 'codergen',
      });
      expect((r.resolve(node) as _TagHandler).tag, 'codergen');
    });

    test('shape-to-type when no explicit type', () {
      final r = registry();
      expect(
          (r.resolve(PipelineNode(id: 'g', attrs: {'shape': 'hexagon'}))
                  as _TagHandler)
              .tag,
          'wait.human');
      expect(
          (r.resolve(PipelineNode(id: 'd', attrs: {'shape': 'diamond'}))
                  as _TagHandler)
              .tag,
          'conditional');
      expect(
          (r.resolve(
                  PipelineNode(id: 's', attrs: {'shape': 'Mdiamond'}))
              as _TagHandler)
          .tag,
          'start');
    });

    test('unrecognized shape falls back to codergen (the default type)', () {
      final r = registry();
      final node = PipelineNode(id: 'm', attrs: {'shape': 'trapezoid'});
      expect(node.handlerType, 'codergen');
      expect((r.resolve(node) as _TagHandler).tag, 'codergen');
    });

    test('a registered type resolves to the registered handler instance', () {
      final r = registry();
      final node = PipelineNode(id: 'n', attrs: {'type': 'wait.human'});
      final resolved = r.resolve(node);
      expect(identical(resolved, r.resolve(node)), isTrue,
          reason: 'handlers are stateless beyond constructor deps; resolve '
              'must hand back the registered instance');
    });

    test('an unknown type resolves to the built-in default fail handler',
        () async {
      final r = registry(); // no handler registered for "mystery"
      final node = PipelineNode(id: 'm', attrs: {'type': 'mystery'});
      final handler = r.resolve(node);
      expect(handler, isNot(isA<_TagHandler>()));

      final g = parseDot('digraph T { m [type=mystery] }');
      final outcome = await handler.execute(
        node: node,
        graph: g,
        context: Context(),
        runStore: MemoryRunStore(),
        cancelSignal: null,
      );
      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, 'no handler registered for type "mystery"');
    });

    test('an installed defaultHandler answers unknown types (engine wiring)',
        () async {
      // Mirrors the host installer (PipelineRunner): defaultHandler is the
      // same codergen handler registered under 'codergen'.
      final r = registry();
      final codergen = r.resolve(PipelineNode(id: 'x'));
      r.defaultHandler = codergen;

      final resolved =
          r.resolve(PipelineNode(id: 'n', attrs: {'type': 'future_kind'}));
      expect(identical(resolved, codergen), isTrue);
    });

    test('re-registering a type routes to the new handler (uniform route)',
        () {
      final r = registry();
      r.register('codergen', _TagHandler('replacement'));
      expect(
          (r.resolve(PipelineNode(id: 'n')) as _TagHandler).tag, 'replacement');
    });
  });
}

/// A handler that only remembers which registration answered.
class _TagHandler implements NodeHandler {
  final String tag;
  _TagHandler(this.tag);

  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async =>
      Outcome.success(notes: tag);
}
