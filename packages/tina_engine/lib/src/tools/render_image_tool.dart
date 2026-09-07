import 'tool.dart';

/// A runtime-local screen capability, installed and cleared by its TUI.
class ImageRenderer {
  Future<String?> Function(String path)? render;
  void coordinate(Future<String?> Function(String path)? callback) {
    render = callback;
  }
}

/// Renders a local image into the terminal panel so the user can see it.
///
/// Delegates the actual decode + blit to the TUI-hosted [ImageRenderer]
/// callback (the same path the `/image` slash command uses).  Because the tool
/// contract is text-only, the result is a short status string; the image itself
/// is a side effect of the render callback.
///
/// Null in headless — [buildAgent] only attaches this tool to the interactive
/// main agent, which is never built outside a TUI.
class RenderTool implements Tool {
  final ImageRenderer? renderer;
  const RenderTool({this.renderer});

  static const _name = 'render_image';

  @override
  ToolSchema get schema => const ToolSchema(
        name: _name,
        description:
            'Render an image from a local file path into the terminal panel so '
            'the user can see it. Provide an absolute or working-directory-'
            'relative path to a PNG/JPEG/GIF/WebP/BMP image. The image is scaled '
            'to fit the focused panel.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Filesystem path to the image file.',
            },
          },
          'required': ['path'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final path = input['path'];
    if (path is! String || path.isEmpty) {
      return ToolResult.error(
          'render_image requires a non-empty "path" string');
    }
    final render = renderer?.render;
    if (render == null) {
      return ToolResult.error(
          'render_image is unavailable outside the interactive TUI');
    }
    final error = await render(path);
    if (error != null) return ToolResult.error(error);
    return ToolResult('Rendered $path');
  }
}
