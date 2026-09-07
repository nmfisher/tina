import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  test('schema advertises the name and a path input', () {
    const tool = RenderTool();
    expect(tool.schema.name, 'render_image');
    final props = tool.schema.inputSchema['properties'] as Map;
    expect(props, contains('path'));
    expect(tool.schema.inputSchema['required'], contains('path'));
  });

  test('empty/missing path is a validation error (render never invoked)',
      () async {
    final renderer = ImageRenderer();
    renderer.coordinate((path) async => fail('render must not be called'));
    final tool = RenderTool(renderer: renderer);

    expect((await tool.execute({'path': ''})).isError, isTrue);
    expect((await tool.execute({})).isError, isTrue);
    expect((await tool.execute({'path': 123})).isError, isTrue);
  });

  test('null renderer (headless) reports unavailable without throwing',
      () async {
    final renderer = ImageRenderer();
    renderer.coordinate(null);
    final tool = RenderTool(renderer: renderer);
    final res = await tool.execute({'path': '/x/y.png'});
    expect(res.isError, isTrue);
    expect(res.content, contains('unavailable'));
  });

  test('delegates to the render callback and reports success', () async {
    var calledWith = '';
    final renderer = ImageRenderer();
    renderer.coordinate((path) async {
      calledWith = path;
      return null;
    });
    final tool = RenderTool(renderer: renderer);
    final res = await tool.execute({'path': 'cat.png'});
    expect(res.isError, isFalse);
    expect(calledWith, 'cat.png');
    expect(res.content, 'Rendered cat.png');
  });

  test('surfaces the render callback error to the caller', () async {
    final renderer = ImageRenderer();
    renderer.coordinate((path) async => 'could not decode image: $path');
    final tool = RenderTool(renderer: renderer);
    final res = await tool.execute({'path': 'cat.png'});
    expect(res.isError, isTrue);
    expect(res.content, contains('could not decode image'));
  });
}
